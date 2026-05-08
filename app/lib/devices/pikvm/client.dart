import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:web_socket_channel/io.dart';

import '../../log/logger.dart';
import '../../models/device.dart';
import '../../storage/credential_store.dart';
import '../../transport/mjpeg.dart';
import '../base.dart';
import 'webrtc.dart';

/// PiKVM client. Auth via HTTP Basic + the X-KVMD-User/X-KVMD-Passwd headers
/// that kvmd accepts directly (no separate login round-trip needed).
///
/// Endpoints (verified against pikvm.lan):
///   GET  /streamer/stream     -> multipart/x-mixed-replace MJPEG
///   GET  /api/info            -> system info JSON
///   GET  /api/streamer        -> streamer state (incl. h264 capability)
///   WS   /api/hid/events      -> HID events (send keys/mouse, receive state)
class PiKvmClient extends DeviceClient {
  PiKvmClient(super.device, super.logger);

  final ValueNotifier<LinkState> _state = ValueNotifier(LinkState.idle);
  @override
  ValueNotifier<LinkState> get state => _state;

  Stream<MjpegFrame>? _frames;
  @override
  Stream<MjpegFrame>? get mjpegFrames => _frames;

  MjpegStream? _mjpeg;
  PiKvmWebRtc? _webrtc;
  IOWebSocketChannel? _hid;
  StreamSubscription<dynamic>? _hidSub;
  Size? _hostVideoSize;
  final ValueNotifier<KeyboardLeds> _leds =
      ValueNotifier(const KeyboardLeds());

  @override
  ValueListenable<KeyboardLeds>? get keyboardLeds => _leds;

  @override
  Size? get hostVideoSize => _hostVideoSize;

  @override
  bool get supportsAbsoluteMouse => true;

  @override
  RTCVideoRenderer? get videoRenderer => _webrtc?.renderer;

  @override
  ValueListenable<bool>? get micMuted => _webrtc?.hasMic == true
      ? _webrtc!.micMuted
      : null;

  @override
  Future<void> setMicMuted(bool muted) =>
      _webrtc?.setMicMuted(muted) ?? Future.value();

  @override
  Future<void> pauseVideo() =>
      _webrtc?.setVideoEnabled(false) ?? Future.value();

  @override
  Future<void> resumeVideo() =>
      _webrtc?.setVideoEnabled(true) ?? Future.value();

  @override
  bool get supportsJiggler => true;

  @override
  Future<bool?> readJiggler() async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req = await http.getUrl(device.baseUri().resolve('/api/hid'));
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      final result = j['result'] as Map<String, dynamic>?;
      final jig = result?['jiggler'] as Map<String, dynamic>?;
      return jig?['enabled'] as bool?;
    } catch (e) {
      logger.w('pikvm', 'readJiggler failed: $e');
      return null;
    } finally {
      http.close(force: true);
    }
  }

  @override
  bool get supportsQualityControls => true;

  @override
  Future<List<StreamQualityControl>?> readStreamQuality() async {
    final state = await _readStreamerState();
    if (state == null) return null;
    final params = state['params'] as Map<String, dynamic>?;
    final limits = state['limits'] as Map<String, dynamic>?;
    final features = state['features'] as Map<String, dynamic>?;
    if (params == null) return null;

    double get(String k, double fallback) =>
        (params[k] as num?)?.toDouble() ?? fallback;
    ({double min, double max}) range(String k, double dMin, double dMax) {
      final lim = limits?[k] as Map<String, dynamic>?;
      return (
        min: (lim?['min'] as num?)?.toDouble() ?? dMin,
        max: (lim?['max'] as num?)?.toDouble() ?? dMax,
      );
    }

    final out = <StreamQualityControl>[];
    final isWebRtc = device.mode == ConnectionMode.webrtc;

    if (!isWebRtc && features?['quality'] == true) {
      out.add(StreamQualityControl(
        key: 'quality',
        label: 'JPEG quality',
        value: get('quality', 70),
        min: 1, max: 100,
        unit: '%',
      ));
    }
    final fpsR = range('desired_fps', 0, 90);
    out.add(StreamQualityControl(
      key: 'desired_fps',
      label: 'FPS limit',
      value: get('desired_fps', 30),
      min: fpsR.min, max: fpsR.max,
      unit: 'fps',
    ));
    if (isWebRtc && features?['h264'] == true) {
      final bR = range('h264_bitrate', 25, 20000);
      out.add(StreamQualityControl(
        key: 'h264_bitrate',
        label: 'H.264 bitrate',
        value: get('h264_bitrate', 5000),
        min: bR.min, max: bR.max,
        step: 25,
        unit: 'kbps',
      ));
      final gR = range('h264_gop', 0, 60);
      out.add(StreamQualityControl(
        key: 'h264_gop',
        label: 'H.264 GOP',
        value: get('h264_gop', 0),
        min: gR.min, max: gR.max,
      ));
    }
    return out;
  }

  @override
  Future<bool> setStreamQualityParam(String key, num value) async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final v = (value is int) ? value : value.round();
      final url = device.baseUri()
          .resolve('/api/streamer/set_params?$key=$v');
      final req = await http.postUrl(url);
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode == 200;
    } catch (e) {
      logger.w('pikvm', 'setStreamQualityParam $key=$value failed: $e');
      return false;
    } finally {
      http.close(force: true);
    }
  }

  @override
  bool get supportsAtx => true;

  @override
  Future<AtxState?> readAtxState() async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req = await http.getUrl(device.baseUri().resolve('/api/atx'));
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      final result = j['result'] as Map<String, dynamic>?;
      final leds = result?['leds'] as Map<String, dynamic>?;
      return AtxState(
        power: leds?['power'] as bool?,
        hdd: leds?['hdd'] as bool?,
      );
    } catch (_) {
      return null;
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<bool> pressAtx(AtxButton button) async {
    final code = switch (button) {
      AtxButton.powerShort => 'power',
      AtxButton.powerLong => 'power_long',
      AtxButton.reset => 'reset',
    };
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final url = device.baseUri()
          .resolve('/api/atx/click?button=$code');
      final req = await http.postUrl(url);
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        logger.w('pikvm', 'pressAtx $code HTTP ${resp.statusCode}');
        return false;
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['ok'] != true) {
        final err = (j['result'] as Map?)?['error_msg'] ?? j['result'];
        logger.w('pikvm', 'pressAtx $code rejected: $err');
        return false;
      }
      logger.i('pikvm', 'atx click: $code');
      return true;
    } catch (e) {
      logger.w('pikvm', 'pressAtx $code failed: $e');
      return false;
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<bool?> setJiggler(bool enabled) async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final url = device.baseUri()
          .resolve('/api/hid/set_params?jiggler=${enabled ? 'true' : 'false'}');
      final req = await http.postUrl(url);
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode != 200) {
        logger.w('pikvm', 'setJiggler HTTP ${resp.statusCode}');
        return null;
      }
      logger.i('pikvm', 'jiggler ${enabled ? "enabled" : "disabled"}');
      return enabled;
    } catch (e) {
      logger.w('pikvm', 'setJiggler failed: $e');
      return null;
    } finally {
      http.close(force: true);
    }
  }

  Map<String, String> _authHeaders = const {};

  @override
  Future<void> connect() async {
    if (_state.value == LinkState.connecting ||
        _state.value == LinkState.connected) {
      return;
    }
    _state.value = LinkState.connecting;
    try {
      final pw = await CredentialStore.getPassword(device.id);
      final user = device.username ?? 'admin';
      _authHeaders = {
        'X-KVMD-User': user,
        'X-KVMD-Passwd': pw ?? '',
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$user:${pw ?? ''}'))}',
        ...device.customHeaders,
      };

      logger.i('pikvm', 'probing ${device.baseUri()}/api/info');
      await _probe();

      // The unified kvmd WS (/api/ws?stream=1) is what holds the streamer
      // alive — kvmd lazy-spawns kvmd-streamer when a stream subscriber
      // appears and lets it die seconds after the last one leaves. Open the
      // WS *before* the stream connection so the streamer is alive by the
      // time MJPEG/Janus tries to attach.
      await _startHid();
      await _checkStreamerLive();
      switch (device.mode) {
        case ConnectionMode.mjpeg:
          await _startMjpeg();
          _state.value = LinkState.connected;
          logger.i('pikvm', 'connected');
          break;
        case ConnectionMode.webrtc:
          await _startWebRtc();
          // _state flips to connected via PiKvmWebRtc's onConnected callback.
          break;
        case ConnectionMode.h264:
          throw UnsupportedError('${device.mode.label} not yet implemented');
      }
    } catch (err, st) {
      logger.e('pikvm', 'connect failed: $err\n$st');
      _state.value = LinkState.errored;
      await _teardown();
      rethrow;
    }
  }

  Future<void> _probe() async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req =
          await http.getUrl(device.baseUri().resolve('/api/info'));
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body =
          await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 5));
      logger.i('pikvm', '/api/info ${resp.statusCode}');
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw AuthException('PiKVM rejected credentials (HTTP '
            '${resp.statusCode})');
      }
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['ok'] != true) {
        throw FormatException('/api/info returned ok=false: ${j['error']}');
      }
    } finally {
      http.close(force: true);
    }
  }

  /// Reads /api/streamer. Returns the parsed `result` block, or null on
  /// non-200 / parse errors.
  Future<Map<String, dynamic>?> _readStreamerState() async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req =
          await http.getUrl(device.baseUri().resolve('/api/streamer'));
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      return j['result'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    } finally {
      http.close(force: true);
    }
  }

  /// Polls /api/streamer until kvmd-streamer reports alive. The HID WS
  /// subscription (`/api/ws?stream=1`, opened just before this) is what
  /// triggers kvmd to spawn it — typically <1s. We just wait. Also caches
  /// the host video resolution for the absolute-pointer pipeline.
  Future<void> _checkStreamerLive() async {
    Map<String, dynamic>? result;
    var waited = 0;
    for (var i = 0; i < 50; i++) {
      result = await _readStreamerState();
      if (result == null) return; // /api/streamer broken — let caller try
      if (result['streamer'] != null) {
        if (i > 0) logger.i('pikvm', 'streamer awake after ${waited}ms');
        break;
      }
      if (i == 0) {
        logger.i('pikvm',
            'streamer dormant — waiting for the WS subscription to wake it');
      }
      await Future.delayed(const Duration(milliseconds: 200));
      waited += 200;
    }
    if (result == null || result['streamer'] == null) {
      throw const HttpException(
        'PiKVM µStreamer did not start within 10s of subscribing on '
        '/api/ws?stream=1. Try `systemctl restart kvmd-streamer` on the '
        'PiKVM or reboot it.',
      );
    }

    final streamer = result['streamer'] as Map<String, dynamic>;
    final source = streamer['source'];
    if (source is Map<String, dynamic>) {
      final res = source['resolution'];
      if (res is Map<String, dynamic>) {
        final w = (res['width'] as num?)?.toDouble();
        final h = (res['height'] as num?)?.toDouble();
        if (w != null && h != null && w > 0 && h > 0) {
          _hostVideoSize = Size(w, h);
        }
      }
      logger.i('pikvm', 'streamer.source online=${source['online']} '
          'resolution=$res '
          'captured_fps=${source['captured_fps']}');
    }
  }

  @override
  Future<bool> setAbsoluteMode(bool absolute) async {
    final mode = absolute ? 'usb' : 'usb_rel';
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final url = device.baseUri()
          .resolve('/api/hid/set_params?mouse_output=$mode');
      logger.i('pikvm', 'switching mouse mode → $mode');
      final req = await http.postUrl(url);
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode != 200) {
        logger.w('pikvm', '/api/hid/set_params HTTP ${resp.statusCode}');
        return false;
      }
      return true;
    } catch (e) {
      logger.e('pikvm', 'setAbsoluteMode failed: $e');
      return false;
    } finally {
      http.close(force: true);
    }
  }

  Future<void> _startMjpeg() async {
    final url = device.baseUri().resolve('/streamer/stream');
    _mjpeg = MjpegStream(
      url: url,
      headers: _authHeaders,
      acceptSelfSigned: device.acceptSelfSigned,
      logger: logger,
    );
    _frames = _mjpeg!.start();
  }

  Future<void> _startWebRtc() async {
    final wsUri = device.wsBaseUri().resolve('/janus/ws');
    _webrtc = PiKvmWebRtc(
      wsUri: wsUri,
      headers: _authHeaders,
      acceptSelfSigned: device.acceptSelfSigned,
      allowAudio: device.webrtcAudioRx,
      allowMic: device.webrtcAudioRx && device.webrtcMicTx,
      micDeviceId: device.micDeviceId,
      logger: logger,
      onConnected: () {
        if (_state.value != LinkState.connected) {
          _state.value = LinkState.connected;
          logger.i('pikvm', 'webrtc connected');
        }
      },
      onError: (e) {
        logger.e('pikvm.webrtc', 'fatal: $e');
        _state.value = LinkState.errored;
      },
    );
    await _webrtc!.start();
  }

  Future<void> _startHid() async {
    // KVMD exposes a unified websocket at /api/ws. Subscribe to hid + stream
    // state so the connection log surfaces useful diagnostics.
    final wsUri = device.wsBaseUri().resolve('/api/ws?hid=1&stream=1');
    logger.i('pikvm', 'WS $wsUri');
    final inner = HttpClient();
    if (device.acceptSelfSigned) {
      inner.badCertificateCallback = (_, __, ___) => true;
    }
    final socket = await WebSocket.connect(
      wsUri.toString(),
      headers: _authHeaders,
      customClient: inner,
    );
    _hid = IOWebSocketChannel(socket);
    _hidSub = _hid!.stream.listen(
      (msg) {
        if (msg is! String) return;
        // PiKVM streams hid_state events; log only at debug volume.
        logger.d('pikvm.hid', msg.length > 200
            ? '${msg.substring(0, 200)}…'
            : msg);
        try {
          final j = jsonDecode(msg) as Map<String, dynamic>;
          if (j['event_type'] != 'hid_state') return;
          final ev = j['event'] as Map<String, dynamic>?;
          final kb = ev?['keyboard'] as Map<String, dynamic>?;
          // Real kvmd shape:
          //   event.keyboard.leds.{caps,num,scroll}
          // Older firmwares sometimes flattened to caps_lock at the top of
          // `keyboard`; accept both so we don't break across upgrades.
          final ledsObj = (kb?['leds'] as Map<String, dynamic>?);
          if (kb == null) return;
          final next = KeyboardLeds(
            capsLock:
                (ledsObj?['caps'] ?? kb['caps_lock']) == true,
            numLock:
                (ledsObj?['num'] ?? kb['num_lock']) == true,
            scrollLock:
                (ledsObj?['scroll'] ?? kb['scroll_lock']) == true,
          );
          if (next != _leds.value) _leds.value = next;
        } catch (_) {
          // Non-JSON / shape we don't recognise — ignore silently.
        }
      },
      onError: (e) => logger.e('pikvm.hid', 'ws error: $e'),
      onDone: () => logger.w('pikvm.hid', 'ws closed'),
    );
  }

  void _send(Map<String, Object?> ev) {
    final c = _hid;
    if (c == null) return;
    c.sink.add(jsonEncode(ev));
  }

  @override
  Future<void> sendKey({required String code, required bool down}) async {
    _send({
      'event_type': 'key',
      'event': {'key': code, 'state': down},
    });
  }

  /// PiKVM exposes `POST /api/hid/print` which accepts raw text in the
  /// body and translates it to physical keypresses using kvmd's
  /// configured keymap. That gives us layout-aware typing — the user's
  /// local keyboard layout and the host's layout don't have to match the
  /// scancodes we'd otherwise infer from char→DOM-code mapping. Configure
  /// the keymap on the PiKVM side (`/etc/kvmd/override.yaml`,
  /// `kvmd: hid: keymap: <code>`) to match the host's layout.
  @override
  bool get supportsTextInput => true;

  @override
  Future<bool> sendText(String text) async {
    if (text.isEmpty) return true;
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      // The device's own default kicks in when the query param is absent,
      // so only attach `?keymap=` when the user picked one explicitly.
      final keymap = device.keymap;
      final url = device.baseUri().resolve(
        keymap == null || keymap.isEmpty
            ? '/api/hid/print'
            : '/api/hid/print?keymap=${Uri.encodeQueryComponent(keymap)}',
      );
      final req = await http.postUrl(url);
      _authHeaders.forEach(req.headers.add);
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      req.write(text);
      final resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode != 200) {
        logger.w('pikvm', 'print HTTP ${resp.statusCode}');
        return false;
      }
      return true;
    } catch (e) {
      logger.w('pikvm', 'print failed: $e');
      return false;
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<HostKeymaps?> getKeymaps() async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req = await http.getUrl(
          device.baseUri().resolve('/api/hid/keymaps'));
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      // Real shape: {ok: true, result: {keymaps: {default, available}}}.
      // Older builds put it at the top level — be defensive about both.
      final inner = (j['result'] ?? j) as Map<String, dynamic>?;
      final km = inner?['keymaps'] as Map<String, dynamic>?;
      if (km == null) return null;
      final available = (km['available'] as List?)
              ?.whereType<String>()
              .toList(growable: false) ??
          const <String>[];
      return HostKeymaps(
        defaultName: (km['default'] as String?) ?? '',
        available: available,
      );
    } catch (e) {
      logger.w('pikvm', 'getKeymaps failed: $e');
      return null;
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<void> sendMouseAbs(double normX, double normY) async {
    // PiKVM expects coords in the int16 range. normX/normY in [0, 1].
    final x = (normX.clamp(0.0, 1.0) * 65535 - 32768).round();
    final y = (normY.clamp(0.0, 1.0) * 65535 - 32768).round();
    _send({
      'event_type': 'mouse_move',
      'event': {
        'to': {'x': x, 'y': y}
      },
    });
  }

  @override
  Future<void> sendMouseRel(double dx, double dy) async {
    _send({
      'event_type': 'mouse_relative',
      'event': {
        'delta': {'x': dx.round(), 'y': dy.round()},
        'squash': true,
      },
    });
  }

  @override
  Future<void> sendMouseButton(MouseButton b, bool down) async {
    final name = switch (b) {
      MouseButton.left => 'left',
      MouseButton.middle => 'middle',
      MouseButton.right => 'right',
      MouseButton.up => 'up',
      MouseButton.down => 'down',
    };
    _send({
      'event_type': 'mouse_button',
      'event': {'button': name, 'state': down},
    });
  }

  @override
  Future<void> sendMouseWheel(double dx, double dy) async {
    _send({
      'event_type': 'mouse_wheel',
      'event': {
        'delta': {'x': dx.round(), 'y': dy.round()},
      },
    });
  }

  Future<void> _teardown() async {
    await _hidSub?.cancel();
    await _hid?.sink.close();
    await _mjpeg?.stop();
    await _webrtc?.dispose();
    _frames = null;
    _hid = null;
    _hidSub = null;
    _mjpeg = null;
    _webrtc = null;
  }

  @override
  Future<void> disconnect() async {
    if (_state.value == LinkState.disconnected) return;
    logger.i('pikvm', 'disconnecting');
    await _teardown();
    _state.value = LinkState.disconnected;
  }
}
