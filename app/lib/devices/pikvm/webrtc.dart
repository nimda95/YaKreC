import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';

import '../../log/logger.dart';

/// PiKVM WebRTC video + 2-way audio via Janus + janus.plugin.ustreamer.
///
/// Janus protocol (JSON-RPC over `/janus/ws`, subprotocol `janus-protocol`):
///   1. WS connect (auth via Basic / X-KVMD-* / auth_token cookie)
///   2. `create` → session_id
///   3. `attach plugin: janus.plugin.ustreamer` → handle_id
///   4. `message {request:"watch", params:{orientation,audio,mic,cam}}`
///   5. uStreamer asynchronously emits a JSEP **offer** (server-offer mode)
///   6. We createAnswer (with mic track added if allowed) and reply with
///      `message {request:"start", jsep:<answer>}`
///   7. Both sides trickle ICE candidates
///   8. Keepalive every 25s; destroy on teardown
class PiKvmWebRtc {
  final Uri wsUri;
  final Map<String, String> headers;
  final bool acceptSelfSigned;
  final bool allowAudio;
  final bool allowMic;
  /// Specific OS-level audio input deviceId to capture from. Null lets the
  /// browser/OS default selection win. Comes from the per-device pref when
  /// the user picked a non-default mic.
  final String? micDeviceId;
  /// Initial mute state to apply to the captured mic track. Restored from
  /// the per-device pref so the user's last mute/unmute choice survives
  /// reconnects and app restarts.
  final bool initialMicMuted;
  final Logger logger;
  final void Function() onConnected;
  final void Function(Object) onError;

  PiKvmWebRtc({
    required this.wsUri,
    required this.headers,
    required this.acceptSelfSigned,
    required this.allowAudio,
    required this.allowMic,
    this.micDeviceId,
    this.initialMicMuted = false,
    required this.logger,
    required this.onConnected,
    required this.onError,
  });

  RTCPeerConnection? _pc;
  IOWebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  Timer? _keepalive;

  int _txCounter = 0;
  int? _sessionId;
  int? _handleId;
  final Map<String, Completer<Map<String, dynamic>>> _pending = {};

  MediaStream? _localStream;
  MediaStreamTrack? _localAudioTrack;
  late final ValueNotifier<bool> micMuted = ValueNotifier(initialMicMuted);
  bool get hasMic => _localAudioTrack != null;

  bool _disposed = false;

  Future<void> start() async {
    await renderer.initialize();
    await _connectWs();
    await _createSession();
    await _attachPlugin();
    await _setupPc();
    if (allowAudio && allowMic) await _setupMic();
    _sendWatch();
    // The actual offer/answer dance happens asynchronously when the server
    // emits a JSEP offer in _onMessage → _handlePluginEvent → _handleOffer.
  }

  // ───── WebSocket / Janus envelope ────────────────────────────────────────

  Future<void> _connectWs() async {
    logger.i('pikvm.janus', 'WS $wsUri');
    final inner = HttpClient();
    if (acceptSelfSigned) {
      inner.badCertificateCallback = (_, __, ___) => true;
    }
    final socket = await WebSocket.connect(
      wsUri.toString(),
      protocols: const ['janus-protocol'],
      headers: headers,
      customClient: inner,
    );
    _ws = IOWebSocketChannel(socket);
    _wsSub = _ws!.stream.listen(
      _onMessage,
      onError: (e) {
        logger.e('pikvm.janus', 'ws error: $e');
        if (!_disposed) onError(e);
      },
      onDone: () => logger.w('pikvm.janus', 'ws closed'),
    );
    logger.i('pikvm.janus', 'ws connected');
  }

  String _newTx() => 'tx${_txCounter++}';

  Future<Map<String, dynamic>> _request(Map<String, dynamic> body) async {
    final tx = _newTx();
    body['transaction'] = tx;
    final completer = Completer<Map<String, dynamic>>();
    _pending[tx] = completer;
    _ws!.sink.add(jsonEncode(body));
    return completer.future
        .timeout(const Duration(seconds: 10), onTimeout: () {
      _pending.remove(tx);
      throw TimeoutException('Janus ${body['janus']} timed out');
    });
  }

  void _send(Map<String, dynamic> body) {
    body['transaction'] = _newTx();
    _ws?.sink.add(jsonEncode(body));
  }

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    try {
      final msg = jsonDecode(raw) as Map<String, dynamic>;
      final type = msg['janus'] as String;
      final tx = msg['transaction'] as String?;

      if (tx != null && _pending.containsKey(tx)) {
        if (type == 'ack') return; // async response coming with same tx
        _pending.remove(tx)!.complete(msg);
        return;
      }

      switch (type) {
        case 'event':
          _handlePluginEvent(msg);
          break;
        case 'webrtcup':
          logger.i('pikvm.janus', 'webrtcup');
          break;
        case 'media':
          logger.d('pikvm.janus', 'media: $msg');
          break;
        case 'slowlink':
          logger.w('pikvm.janus', 'slowlink');
          break;
        case 'hangup':
          logger.w('pikvm.janus', 'hangup: ${msg['reason']}');
          break;
        default:
          logger.d('pikvm.janus', 'unhandled: $type');
      }
    } catch (e) {
      logger.e('pikvm.janus', 'bad ws msg: $e');
    }
  }

  Future<void> _createSession() async {
    final resp = await _request({'janus': 'create'});
    _sessionId = (resp['data'] as Map)['id'] as int;
    logger.i('pikvm.janus', 'session: $_sessionId');
    _keepalive = Timer.periodic(const Duration(seconds: 25), (_) {
      _send({'janus': 'keepalive', 'session_id': _sessionId});
    });
  }

  Future<void> _attachPlugin() async {
    final resp = await _request({
      'janus': 'attach',
      'session_id': _sessionId,
      'plugin': 'janus.plugin.ustreamer',
    });
    _handleId = (resp['data'] as Map)['id'] as int;
    logger.i('pikvm.janus', 'handle: $_handleId');
  }

  void _sendWatch() {
    _send({
      'janus': 'message',
      'session_id': _sessionId,
      'handle_id': _handleId,
      'body': {
        'request': 'watch',
        'params': {
          'orientation': 0,
          'audio': allowAudio,
          'mic': allowMic,
          'cam': false,
        },
      },
    });
    logger.i('pikvm.janus',
        'watch sent (audio=$allowAudio mic=$allowMic)');
  }

  // ───── Plugin events / SDP exchange ──────────────────────────────────────

  Future<void> _handlePluginEvent(Map<String, dynamic> msg) async {
    final pluginData = msg['plugindata'] as Map<String, dynamic>?;
    final data = pluginData?['data'] as Map<String, dynamic>?;
    final result = data?['result'] as Map<String, dynamic>?;
    final status = result?['status'] as String?;
    if (status != null) {
      logger.i('pikvm.janus', 'ustreamer status: $status');
    }
    final jsep = msg['jsep'] as Map<String, dynamic>?;
    if (jsep != null) {
      try {
        await _handleOffer(jsep);
      } catch (e) {
        logger.e('pikvm.webrtc', 'offer/answer failed: $e');
        onError(e);
      }
    }
  }

  Future<void> _handleOffer(Map<String, dynamic> jsep) async {
    final sdp = jsep['sdp'] as String;
    final type = jsep['type'] as String;
    logger.i('pikvm.webrtc', 'received offer (sdp ${sdp.length} bytes)');
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));

    final answer = await _pc!.createAnswer({});
    // PiKVM's webUI applies this Chrome stereo-OPUS workaround on the answer.
    final tweakedSdp = answer.sdp
        ?.replaceAll('useinbandfec=1', 'useinbandfec=1;stereo=1');
    final tweaked = RTCSessionDescription(tweakedSdp, answer.type);
    await _pc!.setLocalDescription(tweaked);
    logger.i('pikvm.webrtc',
        'answer set (sdp ${tweakedSdp?.length ?? 0} bytes)');

    _send({
      'janus': 'message',
      'session_id': _sessionId,
      'handle_id': _handleId,
      'body': {'request': 'start'},
      'jsep': {'type': tweaked.type, 'sdp': tweaked.sdp},
    });
    logger.i('pikvm.janus', 'start sent');
  }

  // ───── PeerConnection / media ────────────────────────────────────────────

  Future<void> _setupPc() async {
    _pc = await createPeerConnection({
      'iceServers': [
        {
          'urls': ['stun:stun.l.google.com:19302']
        }
      ],
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onConnectionState = (s) {
      logger.i('pikvm.webrtc', 'pc state: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnected();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onError(StateError('peer connection failed'));
      }
    };
    _pc!.onIceConnectionState = (s) {
      logger.i('pikvm.webrtc', 'ice state: $s');
    };

    _pc!.onTrack = (event) {
      final track = event.track;
      if (track.kind == 'video' && event.streams.isNotEmpty) {
        renderer.srcObject = event.streams[0];
        logger.i('pikvm.webrtc', 'video track attached');
      } else if (track.kind == 'audio') {
        // Audio tracks play through the OS audio mixer once the connection
        // is up — no renderer needed. Routing (speaker / BT / wired) is
        // applied by ConnectPage._applyAudioSink once the peer reaches the
        // connected state, so it can honour the user's per-device pick.
        logger.i('pikvm.webrtc', 'audio track attached');
      }
    };

    _pc!.onIceCandidate = (c) {
      final cand = c.candidate;
      if (cand == null || cand.isEmpty) {
        _send({
          'janus': 'trickle',
          'session_id': _sessionId,
          'handle_id': _handleId,
          'candidate': {'completed': true},
        });
        return;
      }
      logger.d('pikvm.webrtc', 'local ice: $cand');
      _send({
        'janus': 'trickle',
        'session_id': _sessionId,
        'handle_id': _handleId,
        'candidate': c.toMap(),
      });
    };
  }

  Future<void> _setupMic() async {
    try {
      // If the user picked a specific input, request it via deviceId.exact
      // so getUserMedia fails fast (instead of silently falling back to a
      // different mic) when the chosen device is gone — we surface that
      // through the warning logger below.
      final Object audioConstraint = micDeviceId == null
          ? true
          : {
              'deviceId': {'exact': micDeviceId},
            };
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': audioConstraint,
        'video': false,
      });
      _localAudioTrack = _localStream!.getAudioTracks().firstOrNull;
      if (_localAudioTrack != null && _pc != null) {
        // Honour the per-device persisted mute state so a session resumes
        // exactly as the user left it.
        _localAudioTrack!.enabled = !initialMicMuted;
        await _pc!.addTrack(_localAudioTrack!, _localStream!);
        logger.i('pikvm.webrtc',
            'mic added (${initialMicMuted ? "muted" : "unmuted"})');
      }
    } catch (e) {
      // Mic failure is non-fatal — connection continues without sending audio.
      logger.w('pikvm.webrtc',
          'mic capture failed (continuing without): $e');
    }
  }

  Future<void> setMicMuted(bool muted) async {
    final track = _localAudioTrack;
    if (track == null) return;
    track.enabled = !muted;
    micMuted.value = muted;
    logger.i('pikvm.webrtc', 'mic ${muted ? "muted" : "unmuted"}');
  }

  Future<void> setVideoEnabled(bool enabled) async {
    final pc = _pc;
    if (pc == null) return;
    final receivers = await pc.getReceivers();
    var touched = 0;
    for (final r in receivers) {
      final track = r.track;
      if (track?.kind == 'video') {
        track!.enabled = enabled;
        touched++;
      }
    }
    if (touched > 0) {
      logger.i('pikvm.webrtc',
          'video ${enabled ? "resumed" : "paused"} ($touched track(s))');
    }
  }

  // ───── Teardown ──────────────────────────────────────────────────────────

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _keepalive?.cancel();
    _keepalive = null;
    if (_sessionId != null) {
      try {
        _send({'janus': 'destroy', 'session_id': _sessionId});
      } catch (_) {}
    }
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    if (_localStream != null) {
      for (final t in _localStream!.getTracks()) {
        await t.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }
    await _pc?.close();
    _pc = null;
    renderer.srcObject = null;
    await renderer.dispose();
    micMuted.dispose();
  }
}
