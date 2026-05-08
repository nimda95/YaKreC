import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/io.dart';

import '../../log/logger.dart';
import '../../models/device.dart';
import '../../storage/credential_store.dart';
import '../../transport/mjpeg.dart';
import '../base.dart';
import 'cryptojs.dart';
import 'hid.dart';
import 'webrtc.dart';

/// Hardcoded passphrase used by the NanoKVM frontend (assets/encrypt-*.js)
/// to AES-encrypt the password before POSTing it.
const _passphrase = 'nanokvm-sipeed-2024';

/// Sipeed NanoKVM client. v1: MJPEG display + HID input.
///
/// Endpoints (extracted from the NanoKVM frontend bundle):
///   POST /api/auth/login   -> {"username","password"} returns JWT
///   GET  /api/stream/mjpeg -> multipart MJPEG (cookie auth)
///   WS   /api/ws           -> HID, binary frames:
///                              [type=1, modifier, 0, key1..key6]   (keyboard)
///                              [type=2, buttons, dx, dy, wheel]    (rel mouse)
///
/// Auth: NanoKVM's web UI encrypts the password with CryptoJS-style
/// AES-256-CBC + MD5 KDF using a hardcoded passphrase, then URL-encodes the
/// blob, then puts that in the JSON `password` field. We do the same in
/// [cryptoJsAesEncrypt] so the user types a plain password.
class NanoKvmClient extends DeviceClient {
  NanoKvmClient(super.device, super.logger);

  final ValueNotifier<LinkState> _state = ValueNotifier(LinkState.idle);
  @override
  ValueNotifier<LinkState> get state => _state;

  Stream<MjpegFrame>? _frames;
  @override
  Stream<MjpegFrame>? get mjpegFrames => _frames;

  MjpegStream? _mjpeg;
  NanoKvmWebRtc? _webrtc;
  String? _token;
  IOWebSocketChannel? _hid;
  StreamSubscription<dynamic>? _hidSub;
  Timer? _heartbeat;
  final HidKeyboardState _kb = HidKeyboardState();
  int _mouseButtons = 0;

  @override
  RTCVideoRenderer? get videoRenderer => _webrtc?.renderer;

  @override
  bool get supportsAbsoluteMouse => true;

  @override
  Size? get hostVideoSize {
    final r = _webrtc?.renderer;
    if (r == null) return null;
    if (r.videoWidth == 0 || r.videoHeight == 0) return null;
    return Size(r.videoWidth.toDouble(), r.videoHeight.toDouble());
  }

  @override
  Future<bool> setAbsoluteMode(bool absolute) async {
    // NanoKVM accepts both relative (4-byte) and absolute (6-byte) wire
    // formats over the same WS endpoint without a server-side mode switch.
    // Nothing to do here — the relevant wire format is chosen per call in
    // sendMouseAbs / sendMouseRel.
    return true;
  }

  @override
  Future<void> pauseVideo() =>
      _webrtc?.setVideoEnabled(false) ?? Future.value();

  @override
  Future<void> resumeVideo() =>
      _webrtc?.setVideoEnabled(true) ?? Future.value();

  @override
  bool get supportsJiggler => true;

  String _jigglerMode = 'relative'; // cached so toggling preserves user choice

  @override
  Future<bool?> readJiggler() async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req = await http.getUrl(
          device.baseUri().resolve('/api/vm/mouse-jiggler'));
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 0) return null;
      final data = j['data'] as Map<String, dynamic>?;
      _jigglerMode = (data?['mode'] as String?) ?? _jigglerMode;
      return data?['enabled'] as bool?;
    } catch (e) {
      logger.w('nanokvm', 'readJiggler failed: $e');
      return null;
    } finally {
      http.close(force: true);
    }
  }

  // NanoKVM has no GET endpoint for stream params; the official web UI also
  // just remembers what the browser last set in localStorage. We mirror that
  // by persisting the values per device id in SharedPreferences so they
  // survive app restarts.
  double _nkFps = 30;
  double _nkQuality = 80;
  bool _qualityHydrated = false;

  String _qpKey(String k) => 'nk_${device.id}_$k';

  Future<void> _hydrateQualityCache() async {
    if (_qualityHydrated) return;
    final p = await SharedPreferences.getInstance();
    _nkFps = p.getDouble(_qpKey('fps')) ?? _nkFps;
    _nkQuality = p.getDouble(_qpKey('quality')) ?? _nkQuality;
    _qualityHydrated = true;
  }

  @override
  bool get supportsQualityControls => true;

  @override
  Future<List<StreamQualityControl>?> readStreamQuality() async {
    await _hydrateQualityCache();
    return [
      StreamQualityControl(
        key: 'fps',
        label: 'FPS limit',
        value: _nkFps,
        min: 1, max: 60,
        unit: 'fps',
      ),
      StreamQualityControl(
        key: 'quality',
        label: 'JPEG quality',
        value: _nkQuality,
        min: 1, max: 100,
        unit: '%',
      ),
    ];
  }

  @override
  Future<bool> setStreamQualityParam(String key, num value) async {
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req = await http.postUrl(
          device.baseUri().resolve('/api/vm/screen'));
      _authHeaders.forEach(req.headers.add);
      req.headers.contentType = ContentType.json;
      final v = (value is int) ? value : value.round();
      req.write(jsonEncode({'type': key, 'value': v}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return false;
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 0) {
        logger.w('nanokvm',
            'setStreamQualityParam $key=$v rejected: ${j['msg']}');
        return false;
      }
      // Mirror locally + persist so the next reading (this session or
      // after restart) reflects the user's choice. NanoKVM has no getter,
      // so this cache is the source of truth.
      if (key == 'fps') _nkFps = v.toDouble();
      if (key == 'quality') _nkQuality = v.toDouble();
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_qpKey(key), v.toDouble());
      return true;
    } catch (e) {
      logger.w('nanokvm', 'setStreamQualityParam $key=$value failed: $e');
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
      final req = await http.getUrl(
          device.baseUri().resolve('/api/vm/gpio'));
      _authHeaders.forEach(req.headers.add);
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 0) return null;
      final data = j['data'] as Map<String, dynamic>?;
      return AtxState(
        power: data?['pwr'] as bool?,
        hdd: data?['hdd'] as bool?,
      );
    } catch (_) {
      return null;
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<bool> pressAtx(AtxButton button) async {
    final (type, duration) = switch (button) {
      AtxButton.powerShort => ('power', 300),
      AtxButton.powerLong => ('power', 5000),
      AtxButton.reset => ('reset', 300),
    };
    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req = await http.postUrl(
          device.baseUri().resolve('/api/vm/gpio'));
      _authHeaders.forEach(req.headers.add);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'type': type, 'duration': duration}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        logger.w('nanokvm', 'pressAtx $type/${duration}ms '
            'HTTP ${resp.statusCode}');
        return false;
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 0) {
        logger.w('nanokvm',
            'pressAtx $type/${duration}ms rejected: ${j['msg']}');
        return false;
      }
      logger.i('nanokvm', 'atx click: $type/${duration}ms');
      return true;
    } catch (e) {
      logger.w('nanokvm', 'pressAtx $type/${duration}ms failed: $e');
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
      final req = await http.postUrl(
          device.baseUri().resolve('/api/vm/mouse-jiggler'));
      _authHeaders.forEach(req.headers.add);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'enabled': enabled, 'mode': _jigglerMode}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        logger.w('nanokvm', 'setJiggler HTTP ${resp.statusCode}');
        return null;
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 0) {
        logger.w('nanokvm', 'setJiggler code=${j['code']}: ${j['msg']}');
        return null;
      }
      logger.i('nanokvm', 'jiggler ${enabled ? "enabled" : "disabled"} '
          '(mode=$_jigglerMode)');
      return enabled;
    } catch (e) {
      logger.w('nanokvm', 'setJiggler failed: $e');
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
      final stored = await CredentialStore.getPassword(device.id) ?? '';
      _token = await _acquireToken(stored);
      _authHeaders = {
        'Cookie': 'nano-kvm-token=$_token',
        ...device.customHeaders,
      };
      logger.i('nanokvm', 'token acquired (${_token!.length} chars)');

      switch (device.mode) {
        case ConnectionMode.mjpeg:
          await _startMjpeg();
          await _startHid();
          _state.value = LinkState.connected;
          break;
        case ConnectionMode.webrtc:
          await _startWebRtc();
          await _startHid();
          // WebRTC marks itself connected via the peer-connection state
          // callback — see _startWebRtc.
          break;
        case ConnectionMode.h264:
          throw UnsupportedError('${device.mode.label} not yet implemented');
      }
      logger.i('nanokvm', 'connection routine done');
    } catch (err, st) {
      logger.e('nanokvm', 'connect failed: $err\n$st');
      _state.value = LinkState.errored;
      await _teardown();
      rethrow;
    }
  }

  Future<String> _acquireToken(String password) async {
    final url = device.baseUri().resolve('/api/auth/login');
    final user = device.username ?? 'admin';
    logger.i('nanokvm', 'POST $url (user=$user)');

    final encrypted = Uri.encodeComponent(
      cryptoJsAesEncrypt(password, _passphrase),
    );

    final http = HttpClient();
    if (device.acceptSelfSigned) {
      http.badCertificateCallback = (_, __, ___) => true;
    }
    try {
      final req = await http.postUrl(url);
      req.headers.contentType = ContentType.json;
      device.customHeaders.forEach(req.headers.add);
      req.write(jsonEncode({'username': user, 'password': encrypted}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      logger.i('nanokvm', 'login HTTP ${resp.statusCode}');
      if (resp.statusCode != 200) {
        throw HttpException('login HTTP ${resp.statusCode}: $body');
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 0) {
        final msg = (j['msg'] ?? 'unknown').toString();
        // NanoKVM signals bad credentials with code:-2 and a message
        // containing "invalid". Treat anything that smells like an auth
        // failure as such so the UI can prompt for new credentials.
        if (msg.toLowerCase().contains('invalid') ||
            msg.toLowerCase().contains('password')) {
          throw AuthException('NanoKVM rejected credentials: $msg');
        }
        throw FormatException('login failed: $msg');
      }
      final tok = (j['data'] as Map<String, dynamic>)['token'] as String;
      return tok;
    } finally {
      http.close(force: true);
    }
  }

  Future<void> _startWebRtc() async {
    final wsUri =
        device.wsBaseUri().resolve('/api/stream/h264');
    _webrtc = NanoKvmWebRtc(
      wsUri: wsUri,
      headers: _authHeaders,
      acceptSelfSigned: device.acceptSelfSigned,
      logger: logger,
      onConnected: () {
        if (_state.value != LinkState.connected) {
          _state.value = LinkState.connected;
          logger.i('nanokvm', 'webrtc connected');
        }
      },
      onError: (e) {
        logger.e('nanokvm.webrtc', 'fatal: $e');
        _state.value = LinkState.errored;
      },
    );
    await _webrtc!.start();
  }

  Future<void> _startMjpeg() async {
    final url = device.baseUri().resolve('/api/stream/mjpeg');
    _mjpeg = MjpegStream(
      url: url,
      headers: _authHeaders,
      acceptSelfSigned: device.acceptSelfSigned,
      logger: logger,
    );
    _frames = _mjpeg!.start();
  }

  Future<void> _startHid() async {
    final wsUri = device.wsBaseUri().resolve('/api/ws');
    logger.i('nanokvm', 'WS $wsUri');
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
      (msg) => logger.d('nanokvm.hid', 'recv ${msg.runtimeType}'),
      onError: (e) => logger.e('nanokvm.hid', 'ws error: $e'),
      onDone: () => logger.w('nanokvm.hid', 'ws closed'),
    );
    // The frontend sends a heartbeat every 10s; mirror that so an idle
    // connection doesn't get reaped.
    _heartbeat = Timer.periodic(const Duration(seconds: 10), (_) {
      _hid?.sink.add(Uint8List.fromList([NanoKvmMsg.heartbeat]));
    });
  }

  void _sendKbReport(Uint8List report) {
    final c = _hid;
    if (c == null) return;
    final frame = Uint8List(1 + report.length)
      ..[0] = NanoKvmMsg.keyboard
      ..setRange(1, 1 + report.length, report);
    c.sink.add(frame);
  }

  void _sendMouseRel(int buttons, int dx, int dy, int wheel) {
    final c = _hid;
    if (c == null) return;
    int b(int v) => v.clamp(-127, 127) & 0xFF;
    c.sink.add(Uint8List.fromList(
        [NanoKvmMsg.mouse, buttons, b(dx), b(dy), b(wheel)]));
  }

  /// Absolute mouse report: 6 bytes after the type prefix.
  ///   [2, buttons, x_lo, x_hi, y_lo, y_hi, wheel]
  /// x and y are 16-bit unsigned (0..65535); the NanoKVM frontend multiplies
  /// the normalized 0..1 position by 65535.
  void _sendMouseAbsRaw(int buttons, int x, int y, int wheel) {
    final c = _hid;
    if (c == null) return;
    final cx = x.clamp(0, 0xFFFF);
    final cy = y.clamp(0, 0xFFFF);
    final cw = wheel.clamp(-127, 127) & 0xFF;
    c.sink.add(Uint8List.fromList([
      NanoKvmMsg.mouse,
      buttons,
      cx & 0xFF, (cx >> 8) & 0xFF,
      cy & 0xFF, (cy >> 8) & 0xFF,
      cw,
    ]));
  }

  @override
  Future<void> sendKey({required String code, required bool down}) async {
    final report = _kb.apply(code: code, down: down);
    if (report == null) {
      logger.d('nanokvm.hid', 'unmapped key: $code');
      return;
    }
    _sendKbReport(report);
  }

  /// NanoKVM exposes `POST /api/hid/paste` with JSON
  /// `{content: string, langue: string}`, where `langue` selects which
  /// keymap the server uses to translate text → physical keys (currently
  /// `""` = US base, `"de"`, `"fr"` per upstream `paste.go`). Layout
  /// awareness happens server-side, so the user's local IME (any layout,
  /// any language) round-trips correctly as long as `langue` matches the
  /// host's layout. Defaulting to empty for now — promote to a per-device
  /// setting if you ever need to type AZERTY on a NanoKVM-connected
  /// French host.
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
      final req = await http.postUrl(
          device.baseUri().resolve('/api/hid/paste'));
      _authHeaders.forEach(req.headers.add);
      req.headers.contentType = ContentType.json;
      // NanoKVM only special-cases "de" and "fr"; everything else falls
      // through to base US, including the empty default. Strip a region
      // suffix like "fr-fr" → "fr" so the user can pick the same string
      // PiKVM exposes ("fr-fr") and we still hit the server-side branch.
      final raw = device.keymap ?? '';
      final langue = raw.length >= 2 ? raw.substring(0, 2).toLowerCase() : '';
      req.write(jsonEncode({'content': text, 'langue': langue}));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        logger.w('nanokvm', 'paste HTTP ${resp.statusCode}');
        return false;
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      if (j['code'] != 0) {
        logger.w('nanokvm', 'paste rejected: ${j['msg']}');
        return false;
      }
      return true;
    } catch (e) {
      logger.w('nanokvm', 'paste failed: $e');
      return false;
    } finally {
      http.close(force: true);
    }
  }

  @override
  Future<HostKeymaps?> getKeymaps() async {
    // NanoKVM has no keymaps API — its paste handler hardcodes a base
    // (US) map plus `de` and `fr` overrides. Surface those plus the
    // empty default so the picker still works.
    return const HostKeymaps(
      defaultName: '',
      available: ['', 'de', 'fr'],
    );
  }

  @override
  Future<void> sendMouseRel(double dx, double dy) async {
    _sendMouseRel(_mouseButtons, dx.round(), dy.round(), 0);
  }

  @override
  Future<void> sendMouseButton(MouseButton b, bool down) async {
    final mask = switch (b) {
      MouseButton.left => 0x01,
      MouseButton.right => 0x02,
      MouseButton.middle => 0x04,
      _ => 0,
    };
    if (down) {
      _mouseButtons |= mask;
    } else {
      _mouseButtons &= ~mask;
    }
    _sendMouseRel(_mouseButtons, 0, 0, 0);
  }

  @override
  Future<void> sendMouseWheel(double dx, double dy) async {
    _sendMouseRel(_mouseButtons, 0, 0, dy.round());
  }

  /// [x] and [y] are normalized 0..1 over the host video. The 6-byte
  /// absolute report is accepted on the same WS as the 4-byte relative one;
  /// no mode switch is needed.
  @override
  Future<void> sendMouseAbs(double x, double y) async {
    final px = (x.clamp(0.0, 1.0) * 65535).round();
    final py = (y.clamp(0.0, 1.0) * 65535).round();
    _sendMouseAbsRaw(_mouseButtons, px, py, 0);
  }

  Future<void> _teardown() async {
    _heartbeat?.cancel();
    _heartbeat = null;
    await _hidSub?.cancel();
    await _hid?.sink.close();
    _hid = null;
    _hidSub = null;
    await _mjpeg?.stop();
    _mjpeg = null;
    _frames = null;
    await _webrtc?.dispose();
    _webrtc = null;
  }

  @override
  Future<void> disconnect() async {
    if (_state.value == LinkState.disconnected) return;
    logger.i('nanokvm', 'disconnecting');
    await _teardown();
    _state.value = LinkState.disconnected;
  }
}
