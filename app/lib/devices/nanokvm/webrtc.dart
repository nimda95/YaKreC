import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';

import '../../log/logger.dart';

/// NanoKVM WebRTC video pipeline.
///
/// Signaling protocol (extracted from NanoKVM's frontend bundle):
///   * WS endpoint: `/api/stream/h264` (cookie auth)
///   * Frames are JSON `{event, data}` where `data` is itself a JSON-encoded
///     string of an SDP description or ICE candidate.
///   * Sequence:
///       1. WS open
///       2. Add a recvonly video transceiver → triggers onnegotiationneeded
///       3. createOffer / setLocalDescription, send `video-offer`
///       4. Server replies `video-answer`, we setRemoteDescription
///       5. Both sides trickle `video-candidate` events
///   * NanoKVM does not negotiate audio (`offerToReceiveAudio: false` in
///     their frontend), so this is video-only.
class NanoKvmWebRtc {
  final Uri wsUri;
  final Map<String, String> headers;
  final bool acceptSelfSigned;
  final Logger logger;
  final void Function() onConnected;
  final void Function(Object) onError;

  NanoKvmWebRtc({
    required this.wsUri,
    required this.headers,
    required this.acceptSelfSigned,
    required this.logger,
    required this.onConnected,
    required this.onError,
  });

  RTCPeerConnection? _pc;
  IOWebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  bool _negotiating = false;
  bool _disposed = false;

  Future<void> start() async {
    await renderer.initialize();

    _pc = await createPeerConnection({
      'iceServers': [
        {
          'urls': ['stun:stun.l.google.com:19302']
        }
      ],
      'sdpSemantics': 'unified-plan',
    });

    _pc!.onTrack = (event) {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        renderer.srcObject = event.streams[0];
        logger.i('nanokvm.webrtc', 'video track attached');
      }
    };

    _pc!.onConnectionState = (s) {
      logger.i('nanokvm.webrtc', 'pc state: $s');
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onConnected();
      } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        onError(StateError('peer connection failed'));
      }
    };
    _pc!.onIceConnectionState = (s) {
      logger.i('nanokvm.webrtc', 'ice state: $s');
    };
    _pc!.onIceGatheringState = (s) {
      logger.d('nanokvm.webrtc', 'ice gathering: $s');
    };
    _pc!.onSignalingState = (s) {
      logger.d('nanokvm.webrtc', 'signaling: $s');
    };

    _pc!.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      logger.d('nanokvm.webrtc', 'local ice: ${c.candidate}');
      _send('video-candidate', jsonEncode(c.toMap()));
    };

    // onRenegotiationNeeded isn't reliable in flutter_webrtc, so we drive
    // negotiation explicitly right after the transceiver is added.
    _pc!.onRenegotiationNeeded = () =>
        logger.d('nanokvm.webrtc', 'onRenegotiationNeeded fired');

    await _connectWs();
  }

  Future<void> _connectWs() async {
    logger.i('nanokvm.webrtc', 'WS $wsUri');
    final inner = HttpClient();
    if (acceptSelfSigned) {
      inner.badCertificateCallback = (_, __, ___) => true;
    }
    final socket = await WebSocket.connect(
      wsUri.toString(),
      headers: headers,
      customClient: inner,
    );
    _ws = IOWebSocketChannel(socket);
    _wsSub = _ws!.stream.listen(
      _onWsMessage,
      onError: (e) {
        logger.e('nanokvm.webrtc', 'ws error: $e');
        if (!_disposed) onError(e);
      },
      onDone: () => logger.w('nanokvm.webrtc', 'ws closed'),
    );
    logger.i('nanokvm.webrtc', 'ws connected');

    await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    logger.i('nanokvm.webrtc', 'video transceiver added (recvonly)');

    await _negotiate();
  }

  Future<void> _negotiate() async {
    if (_negotiating) {
      logger.d('nanokvm.webrtc', 'already negotiating');
      return;
    }
    _negotiating = true;
    try {
      final offer = await _pc!.createOffer({
        'offerToReceiveVideo': true,
        'offerToReceiveAudio': false,
      });
      logger.i('nanokvm.webrtc',
          'offer created (sdp ${offer.sdp?.length ?? 0} bytes)');
      await _pc!.setLocalDescription(offer);
      logger.i('nanokvm.webrtc', 'local description set');
      _send('video-offer', jsonEncode(offer.toMap()));
      logger.i('nanokvm.webrtc', 'video-offer sent');
    } catch (e) {
      _negotiating = false;
      logger.e('nanokvm.webrtc', 'negotiate failed: $e');
      onError(e);
    }
  }

  void _onWsMessage(dynamic raw) {
    try {
      if (raw is! String) {
        logger.d('nanokvm.webrtc', 'recv non-string: ${raw.runtimeType}');
        return;
      }
      final outer = jsonDecode(raw) as Map<String, dynamic>;
      final event = outer['event'] as String?;
      final data = outer['data'];
      logger.d('nanokvm.webrtc', 'recv event=$event');
      if (data == null) return;
      final inner = (data is String) ? jsonDecode(data) : data;
      switch (event) {
        case 'video-answer':
          _handleAnswer(inner as Map<String, dynamic>);
          break;
        case 'video-candidate':
          _handleCandidate(inner as Map<String, dynamic>);
          break;
        default:
          logger.d('nanokvm.webrtc', 'unhandled event: $event');
      }
    } catch (e) {
      logger.e('nanokvm.webrtc', 'bad ws msg: $e');
    }
  }

  Future<void> _handleAnswer(Map<String, dynamic> j) async {
    final sdp = j['sdp'] as String?;
    final type = j['type'] as String? ?? 'answer';
    if (sdp == null) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
      _negotiating = false;
      logger.i('nanokvm.webrtc', 'remote answer applied');
    } catch (e) {
      _negotiating = false;
      logger.e('nanokvm.webrtc', 'setRemoteDescription failed: $e');
      onError(e);
    }
  }

  Future<void> _handleCandidate(Map<String, dynamic> j) async {
    final cand = j['candidate'] as String?;
    if (cand == null || cand.isEmpty) return;
    try {
      await _pc!.addCandidate(RTCIceCandidate(
        cand,
        j['sdpMid'] as String?,
        j['sdpMLineIndex'] as int?,
      ));
    } catch (e) {
      logger.w('nanokvm.webrtc', 'addCandidate failed: $e');
    }
  }

  void _send(String event, String dataJson) {
    final msg = jsonEncode({'event': event, 'data': dataJson});
    _ws?.sink.add(msg);
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
      logger.i('nanokvm.webrtc',
          'video ${enabled ? "resumed" : "paused"} ($touched track(s))');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _wsSub?.cancel();
    await _ws?.sink.close();
    await _pc?.close();
    _pc = null;
    renderer.srcObject = null;
    await renderer.dispose();
  }
}
