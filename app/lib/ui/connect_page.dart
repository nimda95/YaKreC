import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../car/car_bridge.dart';
import '../desktop/window_bridge.dart';
import '../devices/base.dart';
import '../devices/factory.dart';
import '../input/keyboard_capture.dart';
import '../input/touch_pointer.dart';
import '../log/logger.dart';
import '../models/device.dart';
import '../models/log_entry.dart';
import '../net/mdns.dart';
import '../pip/pip_bridge.dart';
import '../storage/credential_store.dart';
import '../storage/device_store.dart';
import '../storage/menu_layout_store.dart';
import '../storage/ui_state_store.dart';
import '../transport/mjpeg.dart';
import 'keys_overlay.dart';
import 'on_screen_keyboard.dart';
import 'system_keyboard_capture.dart';

class ConnectPage extends StatefulWidget {
  final Device device;
  const ConnectPage({super.key, required this.device});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage>
    with WidgetsBindingObserver {
  late final Logger _logger = Logger();
  late final DeviceClient _client;

  Object? _lastError;
  StreamSubscription<MjpegFrame>? _frameSub;
  Uint8List? _frame;

  bool _zoomLocked = false;
  int _rotation = 0;
  bool _fullscreen = false;
  bool _debugVisible = false;
  bool _oskVisible = false;
  bool _oskFloating = false;
  // Bumped every time we want a fresh OSK widget (re-centres in floating mode).
  int _oskInstance = 0;
  bool _nativeKbVisible = false;
  bool _keysOverlayVisible = false;
  double _keysOverlayOpacity = 0.85;
  double _oskOpacity = 0.85;
  /// OSK display layout (label rendering only). Derived from
  /// `widget.device.keymap` — the device-side keymap drives both the
  /// host-side text translation AND the OSK label set, so the user only
  /// has to pick the layout once. Anything starting with `fr` renders as
  /// AZERTY; everything else stays on QWERTY (until we ship more layouts).
  KeyboardLayout _oskLayout = KeyboardLayout.qwerty;
  VideoFit _videoFit = VideoFit.stretch;

  static KeyboardLayout _layoutForKeymap(String? keymap) {
    if (keymap == null) return KeyboardLayout.qwerty;
    return keymap.toLowerCase().startsWith('fr')
        ? KeyboardLayout.azerty
        : KeyboardLayout.qwerty;
  }
  /// Persisted floating-OSK origin (top-left). Null on first run; the OSK
  /// widget falls back to its centre-of-screen default and emits a value
  /// once the user drags it.
  Offset? _oskFloatPos;
  /// Persisted vertical position of the keys-overlay bar. Null = default.
  double? _keysOverlayY;
  // Which floating element (osk / keysOverlay) currently owns the inline
  // transparency-adjuster bar. Null = nothing showing.
  _TransparencyTarget? _transparencyTarget;
  bool _absolutePointer = false;
  final TransformationController _viewerTransform = TransformationController();
  final GlobalKey _viewerKey = GlobalKey();
  // Keys the SizedBox that is *exactly* the rendered video rect, so the
  // TouchPointer can measure where the video lives without inferring it
  // from BoxFit assumptions. Mounted only inside _buildDisplay's
  // LayoutBuilder, after a host video size becomes known.
  final GlobalKey _videoBoxKey = GlobalKey();

  late final CarBridge _car;
  int _carFrameCounter = 0;

  late final PipBridge _pip;
  bool _pipMode = false;

  /// True when we tore the connection down on background to save bandwidth.
  /// Tells [_onForeground] to reconnect rather than just resume video.
  bool _disconnectedForBackground = false;

  /// Mouse-jiggler state pulled from the device. Null = unknown / not yet
  /// read / device doesn't expose one.
  bool? _jigglerEnabled;

  /// Forces the connect log into view regardless of connection state. Toggled
  /// from the new menu sheet's Advanced section.
  bool _forceShowLog = false;

  MenuLayout? _menuLayout;

  static const _orientations = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client = buildClient(widget.device, _logger);
    _client.state.addListener(_onState);
    // Eager-init the AA bridge so its method-channel handler is registered
    // even in modes that don't push frames (e.g. WebRTC). Otherwise AA-side
    // events like the Reload tap never reach Flutter.
    _car = CarBridge()
      ..onClick = _onCarClick
      ..onScroll = _onCarScroll
      ..onReload = _onCarReload;
    _pip = PipBridge()
      ..onModeChanged = (inPip) {
        if (mounted) setState(() => _pipMode = inPip);
      };
    _loadPersistedUiState();
    _loadMenuLayout();
    _connect();
  }

  /// Returns the rendered video rect in TouchPointer-local coordinates.
  /// Reads the live render boxes directly (no cached layout) so it stays
  /// correct across orientation changes and runtime re-layouts.
  ///
  /// Returns null while the video box hasn't mounted (e.g. waiting for the
  /// first WebRTC frame, or before host resolution is known).
  Rect? _measureVideoRect() {
    final videoCtx = _videoBoxKey.currentContext;
    final touchCtx = _viewerKey.currentContext;
    if (videoCtx == null || touchCtx == null) return null;
    final videoBox = videoCtx.findRenderObject() as RenderBox?;
    final touchBox = touchCtx.findRenderObject() as RenderBox?;
    if (videoBox == null ||
        touchBox == null ||
        !videoBox.hasSize ||
        !touchBox.hasSize) {
      return null;
    }
    // Origin of videoBox expressed in touchBox's local coordinate system.
    final origin = videoBox.localToGlobal(Offset.zero, ancestor: touchBox);
    return origin & videoBox.size;
  }

  Future<void> _loadPersistedUiState() async {
    final s = await UiStateStore.load(widget.device.id);
    if (!mounted) return;
    setState(() {
      _fullscreen = s.fullscreen;
      _rotation = s.rotation % 4;
      _oskFloating = s.oskFloating;
      _keysOverlayVisible = s.keysOverlayVisible;
      _keysOverlayOpacity = s.keysOverlayOpacity;
      _oskOpacity = s.oskOpacity;
      // OSK label set follows the device-side keymap. Old saves persisted
      // a separate oskLayout — fall back to it only when no keymap was
      // ever picked, so existing users keep their previous look.
      _oskLayout = widget.device.keymap == null
          ? s.oskLayout
          : _layoutForKeymap(widget.device.keymap);
      _videoFit = s.videoFit;
      _oskVisible = s.oskVisible;
      if (_oskVisible) _oskInstance++;
      _absolutePointer = s.absolutePointer;
      _zoomLocked = s.zoomLocked;
      _oskFloatPos = (s.oskFloatX != null && s.oskFloatY != null)
          ? Offset(s.oskFloatX!, s.oskFloatY!)
          : null;
      _keysOverlayY = s.keysOverlayY;
    });
    SystemChrome.setEnabledSystemUIMode(
      _fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    SystemChrome.setPreferredOrientations([_orientations[_rotation]]);
    // Push absolute-mode through to the device on connect — the device's
    // own HID setting may not match what the user persisted (we restored
    // it on dispose last session). Best-effort; failure leaves UI ahead.
    if (_absolutePointer) {
      _client.setAbsoluteMode(true);
    }
  }

  Future<void> _loadMenuLayout() async {
    final layout = await MenuLayoutStore.load();
    if (!mounted) return;
    layout.addListener(_onLayoutChanged);
    setState(() => _menuLayout = layout);
  }

  void _onLayoutChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _persistUiState() => UiStateStore.save(
        widget.device.id,
        DeviceUiState(
          fullscreen: _fullscreen,
          oskFloating: _oskFloating,
          rotation: _rotation,
          keysOverlayVisible: _keysOverlayVisible,
          keysOverlayOpacity: _keysOverlayOpacity,
          oskOpacity: _oskOpacity,
          oskLayout: _oskLayout,
          videoFit: _videoFit,
          oskFloatX: _oskFloatPos?.dx,
          oskFloatY: _oskFloatPos?.dy,
          keysOverlayY: _keysOverlayY,
          oskVisible: _oskVisible,
          absolutePointer: _absolutePointer,
          zoomLocked: _zoomLocked,
        ),
      );

  Future<void> _connect() async {
    try {
      _lastError = null;
      // Resolve mDNS hostnames just-in-time. If the user declines the
      // permission the resolver returns a clear error and we surface it
      // instead of letting the HTTP layer fail with an opaque "no address".
      final ok = await _resolveHostIfNeeded();
      if (!ok) return;
      await _client.connect();
    } on SocketException catch (e) {
      // Stale mDNS cache (device renumbered, switched APs, etc.) is the
      // most likely cause of a sudden connect failure on a hostname that
      // worked before. Drop the cache so the next attempt re-queries.
      if (widget.device.runtimeHost != null) {
        invalidateMdnsCache(widget.device.host);
        widget.device.runtimeHost = null;
      }
      setState(() => _lastError = e);
      return;
    } on AuthException catch (e) {
      _logger.w('auth', '$e — prompting for new credentials');
      if (!mounted) return;
      final retry = await _showAuthDialog();
      if (retry == true) {
        // Tear the (errored) client down and start fresh.
        await _client.disconnect();
        if (!mounted) return;
        _connect();
      } else if (mounted) {
        setState(() => _lastError = e);
      }
      return;
    } catch (e) {
      setState(() => _lastError = e);
      return;
    }
    // Fall through to attach the MJPEG stream listener for the happy path.
    try {
      if (_client.device.mode == ConnectionMode.mjpeg) {
        final s = _client.mjpegFrames;
        if (s != null) {
          _frameSub = s.listen(
            (f) {
              setState(() => _frame = f.bytes);
              // Mirror to Android Auto at ~half rate (no-op when no AA host
              // is bound, so cheap on phone-only sessions).
              if (_carFrameCounter++ % 2 == 0) {
                _car.pushFrame(f.bytes);
              }
            },
            onError: (e) => setState(() => _lastError = e),
          );
        }
      }
    } catch (e) {
      setState(() => _lastError = e);
    }
  }

  Future<void> _onCarClick(double nx, double ny) async {
    await _client.sendMouseAbs(nx, ny);
    await _client.sendMouseButton(MouseButton.left, true);
    await _client.sendMouseButton(MouseButton.left, false);
  }

  void _onCarScroll(double dx, double dy) {
    _client.sendMouseRel(dx, dy);
  }

  void _onCarReload() {
    setState(() => _frame = null);
    _client.disconnect().then((_) => _connect());
  }

  void _onState() {
    setState(() {});
    final connected = _client.state.value == LinkState.connected;
    _pip.setReady(connected);
    if (connected) {
      final size = _client.hostVideoSize;
      if (size != null && size.width > 0 && size.height > 0) {
        _pip.setAspect(size.width.round(), size.height.round());
      }
      _refreshJiggler();
      _applyAudioSink();
    } else {
      _jigglerEnabled = null;
    }
  }

  /// Routes received audio to the user-picked sink. On Android, an
  /// audiooutput "deviceId" coming from flutter_webrtc is actually one of
  /// {bluetooth, wired-headset, speaker, earpiece}. When the user hasn't
  /// pinned a sink we use the BT-preferring helper so a paired headset
  /// keeps audio (the previous setSpeakerphoneOn(true) forced output to
  /// the phone speaker even with a BT headset attached).
  Future<void> _applyAudioSink() async {
    final sink = widget.device.audioSinkId;
    try {
      if (sink == null || sink.isEmpty) {
        if (Platform.isAndroid || Platform.isIOS) {
          await Helper.setSpeakerphoneOnButPreferBluetooth();
        }
        return;
      }
      await Helper.selectAudioOutput(sink);
    } catch (e) {
      _logger.d('audio', 'audio routing for sink=$sink failed: $e');
    }
  }

  Future<void> _refreshJiggler() async {
    if (!_client.supportsJiggler) return;
    final v = await _client.readJiggler();
    if (!mounted) return;
    setState(() => _jigglerEnabled = v);
  }

  void _openMenuSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (_) => _MenuSheet(
        client: _client,
        layout: _menuLayout,
        onAction: _onMenuAction,
        zoomLocked: _zoomLocked,
        fullscreen: _fullscreen,
        debugVisible: _debugVisible,
        oskVisible: _oskVisible,
        oskFloating: _oskFloating,
        nativeKbVisible: _nativeKbVisible,
        micMuted: _client.micMuted,
        absolutePointer: _absolutePointer,
        supportsAbsolute: _client.supportsAbsoluteMouse,
        jigglerEnabled: _jigglerEnabled,
        forceShowLog: _forceShowLog,
        mouseSensitivity: widget.device.mouseSensitivity,
        scrollSensitivity: widget.device.scrollSensitivity,
        onMouseSensitivity: _setMouseSensitivity,
        onScrollSensitivity: _setScrollSensitivity,
        keysOverlayVisible: _keysOverlayVisible,
        onTransparencyTap: _showTransparencyAdjuster,
        currentKeymap: widget.device.keymap,
        onKeymapChanged: _setKeymap,
      ),
    );
  }

  /// Pops a username/password prompt seeded from the device's current
  /// settings. Returns true if the user submitted (and we should retry the
  /// connection), false on cancel.
  Future<bool?> _showAuthDialog() {
    return showDialog<bool>(
      context: context,
      builder: (_) => _AuthDialog(device: widget.device),
    );
  }

  /// If the device's host is a `.local` hostname, runs an mDNS lookup and
  /// stashes the resolved IP on `device.runtimeHost`. On Android 13+ asks
  /// for `NEARBY_WIFI_DEVICES` (with an explanatory pre-prompt) the first
  /// time it's actually needed.
  ///
  /// Returns true to proceed with the connect, false to abort (permission
  /// denied / lookup failed — error already surfaced to the user).
  Future<bool> _resolveHostIfNeeded() async {
    final d = widget.device;
    if (!isMdnsTarget(d.host)) return true;
    if (d.runtimeHost != null) return true;

    if (await needsMdnsPermissionPrompt(d.host)) {
      if (!mounted) return false;
      final ok = await _showMdnsExplainer();
      if (ok != true) {
        setState(() => _lastError =
            'Connecting to ${d.host} needs the Nearby Wi-Fi Devices '
            'permission for mDNS lookup. Use the device IP or grant '
            'the permission and try again.');
        return false;
      }
      final denied = await requestMdnsPermission();
      if (denied != null) {
        if (!mounted) return false;
        setState(() => _lastError = denied.permanentlyDenied
            ? 'Permission permanently denied. Open system settings to '
                'enable Nearby Wi-Fi Devices for this app, or use the '
                'device IP instead.'
            : 'Permission denied — falling back to plain DNS will not '
                'find ${d.host}. Use the device IP instead.');
        return false;
      }
    }

    final res = await resolveLocal(d.host);
    if (!mounted) return false;
    switch (res) {
      case MdnsResolved(:final address):
        // Strip the port — runtimeHost may carry one if user typed
        // host:port. Device.baseUri reuses it as-is.
        d.runtimeHost = address;
        _logger.i('mdns', 'resolved ${d.host} -> $address');
        return true;
      case MdnsNotNeeded():
        return true;
      case MdnsPermissionDenied():
        setState(() => _lastError =
            'mDNS permission denied. Use the device IP for ${d.host}.');
        return false;
      case MdnsFailed(:final reason):
        setState(() => _lastError =
            'Could not resolve ${d.host}: $reason. Check the device is '
            'on the same network or use its IP directly.');
        return false;
    }
  }

  Future<bool?> _showMdnsExplainer() {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.wifi_find),
        title: const Text('Find device on local network'),
        content: const Text(
          'To reach a hostname like "pikvm.local" we need to send a '
          'multicast DNS query on your Wi-Fi. Android calls this the '
          '“Nearby Wi-Fi Devices” permission.\n\n'
          'We only use it to look up KVM hostnames you save — no '
          'background scanning, no location tracking. The next system '
          'prompt is what actually grants it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('I understand'),
          ),
        ],
      ),
    );
  }

  /// Pushes streaming-mode + audio changes through to the device: persists
  /// the new flags onto the [Device], then disconnects and reconnects so
  /// the client picks the new mode up. The mic UI auto-hides/appears via
  /// [_client.micMuted] becoming null/non-null after the rebuild.
  Future<void> _applyStreamingChanges({
    required ConnectionMode mode,
    required bool audioRx,
    required bool micTx,
    String? micDeviceId,
    String? audioSinkId,
  }) async {
    final d = widget.device;
    final unchanged = d.mode == mode &&
        d.webrtcAudioRx == audioRx &&
        d.webrtcMicTx == micTx &&
        d.micDeviceId == micDeviceId &&
        d.audioSinkId == audioSinkId;
    if (unchanged) return;
    d.mode = mode;
    d.webrtcAudioRx = audioRx;
    d.webrtcMicTx = micTx;
    d.micDeviceId = micDeviceId;
    d.audioSinkId = audioSinkId;
    if (mounted) context.read<DeviceStore>().update(d);
    setState(() {
      _frame = null;
      _disconnectedForBackground = false;
      _lastError = null;
    });
    await _client.disconnect();
    if (mounted) _connect();
  }

  /// Updates the device-side keymap. Persisted on the [Device] (so the
  /// next session uses the same value) and immediately propagated to the
  /// OSK display layout. Pass null to revert to the device's own default.
  void _setKeymap(String? name) {
    final d = widget.device;
    final norm = (name == null || name.isEmpty) ? null : name;
    if (d.keymap == norm) return;
    setState(() {
      d.keymap = norm;
      _oskLayout = _layoutForKeymap(norm);
    });
    final store = context.read<DeviceStore>();
    store.update(d);
  }

  void _setMouseSensitivity(double v, {bool persist = false}) {
    setState(() => widget.device.mouseSensitivity = v);
    if (persist) context.read<DeviceStore>().update(widget.device);
  }

  void _setScrollSensitivity(double v, {bool persist = false}) {
    setState(() => widget.device.scrollSensitivity = v);
    if (persist) context.read<DeviceStore>().update(widget.device);
  }

  Future<void> _toggleJiggler() async {
    if (!_client.supportsJiggler) return;
    final cur = _jigglerEnabled ?? false;
    final next = !cur;
    final result = await _client.setJiggler(next);
    if (!mounted) return;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Could not toggle jiggler on the device.'),
      ));
      return;
    }
    setState(() => _jigglerEnabled = result);
  }

  @override
  void dispose() {
    // Restore the global app chrome state we touched.
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // Mirror the Android-side restore on Linux: leave the page un-fullscreen
    // so the home screen shows its normal title bar.
    WindowBridge.setFullscreen(false);
    // Restore PiKVM's HID mode if we switched it. Best-effort.
    if (_absolutePointer) {
      _client.setAbsoluteMode(false);
    }
    WidgetsBinding.instance.removeObserver(this);
    _frameSub?.cancel();
    _client.state.removeListener(_onState);
    _client.disconnect();
    _viewerTransform.dispose();
    _car.clearFrame();
    _car.dispose();
    _pip.setReady(false);
    _pip.dispose();
    _menuLayout?.removeListener(_onLayoutChanged);
    _logger.dispose();
    super.dispose();
  }

  // ───── Lifecycle / power-saving ──────────────────────────────────────────

  /// True when the active profile keeps audio flowing — we keep the
  /// connection up across background and just pause video. Otherwise we
  /// tear the whole thing down to save bandwidth.
  bool get _shouldKeepAudioOnBackground =>
      widget.device.mode == ConnectionMode.webrtc &&
      widget.device.type == DeviceType.pikvm &&
      widget.device.webrtcAudioRx;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // PiP reports as `inactive`, real background as `paused`. We only act on
    // the latter so the floating PiP window keeps full streaming.
    if (_pipMode) return;
    switch (state) {
      case AppLifecycleState.paused:
        _onBackground();
        break;
      case AppLifecycleState.resumed:
        _onForeground();
        break;
      default:
        break;
    }
  }

  void _onBackground() {
    if (_shouldKeepAudioOnBackground) {
      _logger.i('lifecycle',
          'backgrounded — pausing video, keeping audio + mic');
      _client.pauseVideo();
    } else {
      _logger.i('lifecycle',
          'backgrounded — disconnecting (no audio path on this profile)');
      _disconnectedForBackground = true;
      _client.disconnect();
    }
  }

  void _onForeground() {
    if (_disconnectedForBackground) {
      _disconnectedForBackground = false;
      _logger.i('lifecycle', 'foregrounded — reconnecting');
      setState(() => _frame = null);
      _connect();
    } else {
      _logger.i('lifecycle', 'foregrounded — resuming video');
      _client.resumeVideo();
    }
  }

  void _rotate() {
    setState(() => _rotation = (_rotation + 1) % 4);
    // No-op on Linux desktop, takes effect on Android.
    SystemChrome.setPreferredOrientations([_orientations[_rotation]]);
    _persistUiState();
  }

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    SystemChrome.setEnabledSystemUIMode(
      _fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    // On Linux the SystemChrome call is a no-op; the GTK runner only
    // hides the title / header bar when we explicitly call
    // gtk_window_fullscreen() through the kvm/window channel.
    WindowBridge.setFullscreen(_fullscreen);
    _persistUiState();
  }

  /// Per-action metadata: icon + label + whether the action is currently
  /// available given device capabilities and current state. Single source of
  /// truth for both the popup menu and the toolbar.
  ({IconData icon, String label, bool available}) _meta(_MenuAction a) {
    final muted = _client.micMuted?.value ?? false;
    switch (a) {
      case _MenuAction.disconnect:
        return (icon: Icons.power_settings_new, label: 'Disconnect', available: true);
      case _MenuAction.toggleZoomLock:
        return (
          icon: _zoomLocked ? Icons.lock : Icons.lock_open,
          label: _zoomLocked ? 'Unlock zoom' : 'Lock zoom',
          available: true,
        );
      case _MenuAction.rotate:
        return (icon: Icons.screen_rotation, label: 'Rotate device', available: true);
      case _MenuAction.toggleFullscreen:
        return (
          icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          label: _fullscreen ? 'Exit fullscreen' : 'Fullscreen',
          available: true,
        );
      case _MenuAction.toggleDebug:
        return (
          icon: _debugVisible ? Icons.bug_report : Icons.bug_report_outlined,
          label: _debugVisible ? 'Hide debug info' : 'Debug info',
          available: true,
        );
      case _MenuAction.toggleMicMute:
        return (
          icon: muted ? Icons.mic_off : Icons.mic,
          label: muted ? 'Unmute microphone' : 'Mute microphone',
          available: _client.micMuted != null,
        );
      case _MenuAction.toggleAbsolutePointer:
        return (
          icon: _absolutePointer ? Icons.touch_app : Icons.mouse_outlined,
          label: _absolutePointer ? 'Absolute pointer (on)' : 'Absolute pointer (off)',
          available: _client.supportsAbsoluteMouse,
        );
      case _MenuAction.enterPip:
        return (
          icon: Icons.picture_in_picture_alt,
          label: 'Picture in Picture',
          available: Platform.isAndroid &&
              _client.state.value == LinkState.connected,
        );
      case _MenuAction.toggleJiggler:
        final on = _jigglerEnabled ?? false;
        return (
          icon: on ? Icons.directions_run : Icons.do_not_disturb_on_outlined,
          label: _jigglerEnabled == null
              ? 'Mouse jiggler …'
              : (on ? 'Stop mouse jiggler' : 'Start mouse jiggler'),
          available: _client.supportsJiggler &&
              _client.state.value == LinkState.connected,
        );
      case _MenuAction.power:
        return (
          icon: Icons.power_settings_new,
          label: 'Power…',
          available: _client.supportsAtx &&
              _client.state.value == LinkState.connected,
        );
      case _MenuAction.qualityControls:
        return (
          icon: Icons.tune,
          label: 'Stream quality…',
          available: _client.supportsQualityControls &&
              _client.state.value == LinkState.connected,
        );
      case _MenuAction.streaming:
        return (
          icon: Icons.cast_connected,
          label: 'Streaming…',
          available: true,
        );
      case _MenuAction.showLog:
        return (icon: Icons.notes, label: 'View logs', available: true);
      case _MenuAction.specialKeys:
        return (icon: Icons.bolt, label: 'Special keys', available: true);
      case _MenuAction.osKeyboard:
        return (
          icon: _oskVisible ? Icons.keyboard_hide : Icons.keyboard,
          label: _oskVisible ? 'Hide on-screen keyboard' : 'On-screen keyboard',
          available: true,
        );
      case _MenuAction.toggleOskFloating:
        return (
          icon: _oskFloating ? Icons.toggle_on : Icons.toggle_off,
          label: _oskFloating ? 'Floating mode (on)' : 'Floating mode (off)',
          available: true,
        );
      case _MenuAction.nativeKeyboard:
        return (
          icon: _nativeKbVisible ? Icons.keyboard_hide : Icons.keyboard_alt_outlined,
          label: _nativeKbVisible ? 'Hide native keyboard' : 'Native keyboard',
          available: true,
        );
      case _MenuAction.keysOverlay:
        return (
          icon: _keysOverlayVisible
              ? Icons.keyboard_double_arrow_up
              : Icons.keyboard_command_key,
          label:
              _keysOverlayVisible ? 'Hide keys overlay' : 'Keys overlay',
          available: true,
        );
    }
  }

  List<Widget> _toolbarActions() {
    final layout = _menuLayout;
    if (layout == null) return const [];
    final out = <Widget>[];
    for (final a in _MenuAction.values) {
      if (!layout.inToolbar(a.name)) continue;
      final m = _meta(a);
      if (!m.available) continue;
      out.add(IconButton(
        icon: Icon(m.icon),
        tooltip: m.label,
        onPressed: () => _onMenuAction(a),
      ));
    }
    return out;
  }

  bool get _showLog {
    if (_forceShowLog) return true;
    if (_client.state.value != LinkState.connected) return true;
    // For MJPEG we wait for the first frame before swapping the log out.
    // For WebRTC the renderer takes care of itself once connected.
    if (widget.device.mode == ConnectionMode.mjpeg && _frame == null) {
      return true;
    }
    return false;
  }

  Future<void> _exportLogs() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final fname =
          'kvm-log-${widget.device.name}-${DateTime.now().millisecondsSinceEpoch}.txt';
      final path = '${dir.path}${Platform.pathSeparator}$fname';
      await File(path).writeAsString(_logger.exportText());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved to $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pipMode) return _buildPip();
    final hideAppBar = _fullscreen && !_showLog;
    return Scaffold(
      appBar: hideAppBar
          ? null
          : AppBar(
              title: Text(widget.device.name),
              actions: [
                ..._toolbarActions(),
                if (_showLog)
                  IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: 'Export logs',
                    onPressed: _exportLogs,
                  ),
                if (_lastError != null)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Retry',
                    onPressed: () {
                      setState(() => _frame = null);
                      _connect();
                    },
                  ),
              ],
            ),
      body: _showLog ? _buildLog() : _buildDisplay(),
    );
  }

  Widget _buildLog() {
    return _LogView(logger: _logger, error: _lastError);
  }

  /// PiP variant: no chrome, no overlays — just the live frame filling the
  /// floating window. Tapping the PiP back to fullscreen lands the user on
  /// the regular [build] above (same Activity, same connect page).
  Widget _buildPip() {
    Widget content;
    switch (widget.device.mode) {
      case ConnectionMode.mjpeg:
        content = _frame == null
            ? const SizedBox.shrink()
            : Image.memory(
                _frame!,
                gaplessPlayback: true,
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
              );
        break;
      case ConnectionMode.webrtc:
      case ConnectionMode.h264:
        final renderer = _client.videoRenderer;
        content = (renderer == null)
            ? const SizedBox.shrink()
            : RTCVideoView(
                renderer,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              );
        break;
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: content),
    );
  }

  Widget _buildDisplay() {
    Widget content;
    switch (widget.device.mode) {
      case ConnectionMode.mjpeg:
        content = _frame == null
            ? const CircularProgressIndicator()
            : Image.memory(
                _frame!,
                gaplessPlayback: true,
                // We're rendering into a SizedBox sized to the parent's
                // full constraints (stretch-to-fill), so use BoxFit.fill
                // explicitly. The video may look slightly stretched on
                // aspect-mismatched screens — accuracy is preserved
                // because TouchPointer measures the actual rendered rect.
                fit: BoxFit.fill,
              );
        break;
      case ConnectionMode.webrtc:
      case ConnectionMode.h264:
        final renderer = _client.videoRenderer;
        if (renderer == null) {
          content = const CircularProgressIndicator();
        } else {
          // RTCVideoView only exposes Contain (letterbox) and Cover (crop)
          // — no real "stretch to fill". To get true fill (covers screen,
          // hides nothing, slight distortion on aspect mismatch), we
          // render the view at the host's native dimensions and let a
          // FittedBox(fit:fill) stretch the whole thing to the parent.
          final nativeSize = _client.hostVideoSize ?? const Size(16, 9);
          content = FittedBox(
            fit: BoxFit.fill,
            // FittedBox defaults to Clip.none — its child is laid out
            // unconstrained at native size and scaled to fit, but if the
            // scale math races with a host-resolution update the texture
            // can briefly render past the FittedBox bounds. Clip it.
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: nativeSize.width,
              height: nativeSize.height,
              child: RTCVideoView(
                renderer,
                objectFit:
                    RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
          );
        }
        break;
    }
    // Lay out the video in a SizedBox that is *exactly* the parent's full
    // constraints. The child content above stretches into it, so the
    // rendered rect equals the SizedBox bounds — meaning TouchPointer
    // measures the same rect we'd compute analytically, which keeps
    // absolute-pointer accuracy correct without any BoxFit guesswork.
    //
    // ClipRect wraps the SizedBox: with the FittedBox/Texture path used by
    // RTCVideoView, internal scaling can otherwise leak past the layout
    // bounds during native-size transitions (e.g. when host_video_size
    // updates after the first frame), making the video appear to extend
    // past the window. The clip is layout-cheap and bounds the visual
    // strictly to the rect we report to TouchPointer, so what the user
    // touches always corresponds to what they see.
    final hostVideo = _client.hostVideoSize;
    final display = LayoutBuilder(
      builder: (ctx, constraints) {
        final maxW =
            constraints.hasBoundedWidth ? constraints.maxWidth : 0.0;
        final maxH =
            constraints.hasBoundedHeight ? constraints.maxHeight : 0.0;
        // Stretch fills the whole viewport; Contain shrinks the SizedBox
        // to the BoxFit.contain rect of the host's aspect, leaving black
        // bars where they belong. _videoBoxKey wraps the actual rendered
        // box, so TouchPointer's measurement adapts automatically and
        // touch accuracy is preserved in both modes.
        double boxW = maxW;
        double boxH = maxH;
        if (_videoFit == VideoFit.contain && hostVideo != null) {
          final wAspect = maxW / maxH;
          final vAspect = hostVideo.width / hostVideo.height;
          if (wAspect > vAspect) {
            boxH = maxH;
            boxW = boxH * vAspect;
          } else {
            boxW = maxW;
            boxH = boxW / vAspect;
          }
        }
        return ColoredBox(
          color: Colors.black,
          child: SizedBox(
            width: maxW,
            height: maxH,
            child: Center(
              child: ClipRect(
                child: SizedBox(
                  key: _videoBoxKey,
                  width: boxW,
                  height: boxH,
                  child: content,
                ),
              ),
            ),
          ),
        );
      },
    );

    final viewerKey = ValueKey('viewer-$_zoomLocked');
    // Single-finger pan is reserved for cursor movement (TouchPointer); the
    // InteractiveViewer only handles two-finger pinch.
    final viewer = InteractiveViewer(
      key: viewerKey,
      transformationController: _viewerTransform,
      panEnabled: false,
      // In touchscreen (absolute) mode the controller MUST stay at identity
      // — otherwise the inverse transform inside TouchPointer can't recover
      // the original tap position and the cursor drifts at the edges. So
      // gate scale on absolute pointer being off.
      scaleEnabled: !_zoomLocked && !_absolutePointer,
      minScale: 0.5,
      maxScale: 4.0,
      child: display,
    );

    return KeyboardCapture(
      client: _client,
      child: Stack(
        children: [
          Positioned.fill(
            child: TouchPointer(
              key: _viewerKey,
              client: _client,
              zoomLocked: _zoomLocked,
              useAbsolute: _absolutePointer,
              hostVideoSize: () => _client.hostVideoSize,
              videoRect: _measureVideoRect,
              viewerTransform: _viewerTransform,
              mouseSensitivity: widget.device.mouseSensitivity,
              scrollSensitivity: widget.device.scrollSensitivity,
              child: viewer,
            ),
          ),
          if (_debugVisible) _DebugOverlay(
            device: widget.device,
            client: _client,
            frame: _frame,
            onClose: () => setState(() => _debugVisible = false),
          ),
          if (_oskVisible && !_oskFloating)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: OnScreenKeyboard(
                key: ValueKey('osk-$_oskInstance'),
                client: _client,
                floating: false,
                opacity: _oskOpacity,
                layout: _oskLayout,
                onHide: () {
                  setState(() => _oskVisible = false);
                  _persistUiState();
                },
              ),
            ),
          if (_oskVisible && _oskFloating)
            OnScreenKeyboard(
              key: ValueKey('osk-$_oskInstance'),
              client: _client,
              floating: true,
              opacity: _oskOpacity,
              layout: _oskLayout,
              initialPosition: _oskFloatPos,
              onPositionChanged: (p) {
                _oskFloatPos = p;
                _persistUiState();
              },
              onHide: () {
                setState(() => _oskVisible = false);
                _persistUiState();
              },
            ),
          if (_keysOverlayVisible)
            KeysOverlay(
              client: _client,
              opacity: _keysOverlayOpacity,
              initialY: _keysOverlayY,
              onPositionChanged: (y) {
                _keysOverlayY = y;
                _persistUiState();
              },
              onHide: () {
                setState(() => _keysOverlayVisible = false);
                _persistUiState();
              },
            ),
          if (_transparencyTarget != null)
            _TransparencyAdjuster(
              target: _transparencyTarget!,
              opacity: _transparencyTarget == _TransparencyTarget.osk
                  ? _oskOpacity
                  : _keysOverlayOpacity,
              oskFloating: _oskFloating,
              onOpacity: (v) {
                setState(() {
                  if (_transparencyTarget == _TransparencyTarget.osk) {
                    _oskOpacity = v;
                  } else {
                    _keysOverlayOpacity = v;
                  }
                });
              },
              onOpacityCommit: _persistUiState,
              onToggleDocked: () {
                setState(() {
                  _oskFloating = !_oskFloating;
                  if (_oskVisible) _oskInstance++;
                });
                _persistUiState();
              },
              onClose: () =>
                  setState(() => _transparencyTarget = null),
            ),
          if (_nativeKbVisible)
            SystemKeyboardCapture(
              client: _client,
              onClose: () => setState(() => _nativeKbVisible = false),
            ),
          _OptionsButton(
            onTap: _openMenuSheet,
            micMuted: _client.micMuted,
            onLongPressMute: _client.micMuted == null
                ? null
                : () => _onMenuAction(_MenuAction.toggleMicMute),
          ),
        ],
      ),
    );
  }

  void _onMenuAction(_MenuAction a) {
    switch (a) {
      case _MenuAction.disconnect:
        // The menu sheet's own pop is mid-flight when this fires; popping
        // the connect page in the same frame races with that pop and gets
        // swallowed. Defer until the sheet is fully gone.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).maybePop();
        });
        break;
      case _MenuAction.toggleZoomLock:
        setState(() => _zoomLocked = !_zoomLocked);
        _persistUiState();
        break;
      case _MenuAction.rotate:
        _rotate();
        break;
      case _MenuAction.toggleFullscreen:
        _toggleFullscreen();
        break;
      case _MenuAction.toggleDebug:
        setState(() => _debugVisible = !_debugVisible);
        break;
      case _MenuAction.showLog:
        setState(() => _forceShowLog = !_forceShowLog);
        break;
      case _MenuAction.specialKeys:
        showModalBottomSheet(
          context: context,
          builder: (_) => _SpecialKeysSheet(client: _client),
        );
        break;
      case _MenuAction.osKeyboard:
        setState(() {
          _oskVisible = !_oskVisible;
          if (_oskVisible) _oskInstance++;
        });
        _persistUiState();
        break;
      case _MenuAction.toggleOskFloating:
        setState(() {
          _oskFloating = !_oskFloating;
          // Re-mount the OSK so it re-centres on the new layout.
          if (_oskVisible) _oskInstance++;
        });
        _persistUiState();
        break;
      case _MenuAction.nativeKeyboard:
        setState(() => _nativeKbVisible = !_nativeKbVisible);
        break;
      case _MenuAction.toggleMicMute:
        final muted = _client.micMuted?.value ?? false;
        final next = !muted;
        _client.setMicMuted(next);
        // Persist so the next session restores the same mute state.
        widget.device.micMuted = next;
        context.read<DeviceStore>().update(widget.device);
        break;
      case _MenuAction.toggleAbsolutePointer:
        () async {
          final next = !_absolutePointer;
          final ok = await _client.setAbsoluteMode(next);
          if (!mounted) return;
          if (ok) {
            setState(() {
              _absolutePointer = next;
              if (next) {
                // Touchscreen mode wants 1:1 mapping — clear any residual
                // pinch-zoom transform so finger position lands exactly.
                _viewerTransform.value = Matrix4.identity();
              }
            });
            _persistUiState();
          } else {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Could not switch HID mode on the device.'),
            ));
          }
        }();
        break;
      case _MenuAction.enterPip:
        _pip.enter();
        break;
      case _MenuAction.toggleJiggler:
        _toggleJiggler();
        break;
      case _MenuAction.power:
        showModalBottomSheet(
          context: context,
          builder: (_) => _AtxSheet(client: _client),
        );
        break;
      case _MenuAction.qualityControls:
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          builder: (_) => _QualitySheet(client: _client),
        );
        break;
      case _MenuAction.streaming:
        showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          backgroundColor: Theme.of(context).colorScheme.surface,
          builder: (_) => _StreamingSheet(
            device: widget.device,
            onApply: _applyStreamingChanges,
            currentVideoFit: _videoFit,
            onVideoFit: (fit) {
              setState(() => _videoFit = fit);
              _persistUiState();
            },
          ),
        );
        break;
      case _MenuAction.keysOverlay:
        setState(() => _keysOverlayVisible = !_keysOverlayVisible);
        _persistUiState();
        break;
    }
  }

  /// Pops the floating "transparency adjuster" bar, scoped to either the OSK
  /// or the keys-overlay. Only one is shown at a time. Tapping the same row
  /// label again toggles it off; tapping the other swaps the target.
  void _showTransparencyAdjuster(_TransparencyTarget target) {
    setState(() {
      _transparencyTarget =
          _transparencyTarget == target ? null : target;
    });
  }
}

enum _MenuAction {
  disconnect,
  toggleZoomLock,
  rotate,
  toggleFullscreen,
  toggleDebug,
  toggleMicMute,
  toggleAbsolutePointer,
  toggleJiggler,
  enterPip,
  power,
  qualityControls,
  streaming,
  showLog,
  specialKeys,
  osKeyboard,
  toggleOskFloating,
  nativeKeyboard,
  keysOverlay,
}

/// Which floating UI element the inline transparency-adjuster bar is editing.
/// The bar pops up after the user taps the *label* (not the switch) of the
/// matching menu row; switching to a different row replaces the target.
enum _TransparencyTarget { osk, keysOverlay }

class _LogView extends StatefulWidget {
  final Logger logger;
  final Object? error;
  const _LogView({required this.logger, this.error});

  @override
  State<_LogView> createState() => _LogViewState();
}

class _LogViewState extends State<_LogView> {
  StreamSubscription<LogEntry>? _sub;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _sub = widget.logger.stream.listen((_) {
      if (!mounted) return;
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.logger.entries;
    return Column(
      children: [
        if (widget.error != null)
          Container(
            color: Theme.of(context).colorScheme.errorContainer,
            padding: const EdgeInsets.all(12),
            width: double.infinity,
            child: Text(
              'Connection failed: ${widget.error}',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: entries.length,
            padding: const EdgeInsets.all(8),
            itemBuilder: (_, i) {
              final e = entries[i];
              return Text(
                e.formatted(),
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: switch (e.level) {
                    LogLevel.error => Colors.redAccent,
                    LogLevel.warn => Colors.amberAccent,
                    LogLevel.info => null,
                    LogLevel.debug => Colors.grey,
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Draggable floating button. Tap → opens the menu sheet (handled by the
/// parent); long-press → quick mic-mute toggle when a mic track exists. The
/// button shows a coloured ring around the menu icon mirroring the live
/// mic-mute state (green = unmuted, red = muted).
class _OptionsButton extends StatefulWidget {
  final VoidCallback onTap;
  final ValueListenable<bool>? micMuted;
  final VoidCallback? onLongPressMute;
  const _OptionsButton({
    required this.onTap,
    required this.micMuted,
    required this.onLongPressMute,
  });

  @override
  State<_OptionsButton> createState() => _OptionsButtonState();
}

class _OptionsButtonState extends State<_OptionsButton> {
  Offset _pos = const Offset(20, 20);

  @override
  void initState() {
    super.initState();
    widget.micMuted?.addListener(_onMicMute);
  }

  @override
  void didUpdateWidget(_OptionsButton old) {
    super.didUpdateWidget(old);
    if (old.micMuted != widget.micMuted) {
      old.micMuted?.removeListener(_onMicMute);
      widget.micMuted?.addListener(_onMicMute);
    }
  }

  @override
  void dispose() {
    widget.micMuted?.removeListener(_onMicMute);
    super.dispose();
  }

  void _onMicMute() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final muted = widget.micMuted?.value ?? false;
    final hasMic = widget.micMuted != null;

    Widget icon = const CircleAvatar(child: Icon(Icons.menu));
    if (hasMic) {
      icon = Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: muted ? Colors.redAccent : Colors.greenAccent,
            width: 3,
          ),
        ),
        child: icon,
      );
    }

    return Positioned(
      left: _pos.dx,
      top: _pos.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => setState(() => _pos += d.delta),
        onTap: widget.onTap,
        onLongPress: widget.onLongPressMute == null
            ? null
            : () {
                HapticFeedback.mediumImpact();
                widget.onLongPressMute!();
              },
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: icon,
        ),
      ),
    );
  }
}

/// The new dedicated menu view. Replaces the old PopupMenu. Hosts a Power
/// header (live LED + Power-control button), grouped action sections, and an
/// Advanced section at the bottom with switches for log + debug overlay.
class _MenuSheet extends StatefulWidget {
  final DeviceClient client;
  final MenuLayout? layout;
  final void Function(_MenuAction) onAction;

  // State snapshots for label / icon rendering.
  final bool zoomLocked;
  final bool fullscreen;
  final bool debugVisible;
  final bool oskVisible;
  final bool oskFloating;
  final bool nativeKbVisible;
  final ValueListenable<bool>? micMuted;
  final bool absolutePointer;
  final bool supportsAbsolute;
  final bool? jigglerEnabled;
  final bool forceShowLog;
  final double mouseSensitivity;
  final double scrollSensitivity;
  final bool keysOverlayVisible;

  /// Live value updates while dragging (`persist:false`); commit-to-store
  /// fires on release (`persist:true`).
  final void Function(double v, {bool persist}) onMouseSensitivity;
  final void Function(double v, {bool persist}) onScrollSensitivity;

  /// Tapping the OSK / keys-overlay row *label* closes the menu and asks
  /// the connect page to surface a small floating transparency-adjuster
  /// bar for that target. Different from [onAction] so the parent can
  /// distinguish "switch flipped → toggle visibility" from "label tapped
  /// → open transparency bar".
  final void Function(_TransparencyTarget) onTransparencyTap;

  /// Currently-selected device-side keymap, or null to use the device's
  /// own default. Drives both `/api/hid/print` translation and the OSK
  /// label rendering (the latter via the connect page's derivation
  /// helper).
  final String? currentKeymap;
  final ValueChanged<String?> onKeymapChanged;

  const _MenuSheet({
    required this.client,
    required this.layout,
    required this.onAction,
    required this.zoomLocked,
    required this.fullscreen,
    required this.debugVisible,
    required this.oskVisible,
    required this.oskFloating,
    required this.nativeKbVisible,
    required this.micMuted,
    required this.absolutePointer,
    required this.supportsAbsolute,
    required this.jigglerEnabled,
    required this.forceShowLog,
    required this.mouseSensitivity,
    required this.scrollSensitivity,
    required this.onMouseSensitivity,
    required this.onScrollSensitivity,
    required this.keysOverlayVisible,
    required this.onTransparencyTap,
    required this.currentKeymap,
    required this.onKeymapChanged,
  });

  bool get hasMic => micMuted != null;

  @override
  State<_MenuSheet> createState() => _MenuSheetState();
}

class _MenuSheetState extends State<_MenuSheet> {
  // Mirror parent state for in-sheet toggles, so the row updates instantly
  // before the parent's setState propagates back.
  late bool _oskFloating = widget.oskFloating;
  late bool? _jigglerEnabled = widget.jigglerEnabled;
  late bool _debugVisible = widget.debugVisible;
  late bool _forceShowLog = widget.forceShowLog;
  // The parent setState that flips visibility doesn't rebuild this modal
  // route, so widget.oskVisible / keysOverlayVisible would stay stale and
  // the switches would visually freeze. Mirror locally and update on flip.
  late bool _oskVisible = widget.oskVisible;
  late bool _keysOverlayVisible = widget.keysOverlayVisible;
  // Sliders need a live local value so the thumb tracks the user's drag —
  // otherwise the parent's setState updates the device but the slider snaps
  // back to whatever was captured at sheet creation.
  late double _mouseSensitivity = widget.mouseSensitivity;
  late double _scrollSensitivity = widget.scrollSensitivity;

  AtxState? _atx;
  bool _atxLoading = false;

  /// Cached keymaps the device exposes. Null while loading; populated
  /// after the async fetch in initState. Same lifecycle as ATX state.
  HostKeymaps? _keymaps;
  bool _keymapsLoading = true;
  /// Mirror of [widget.currentKeymap] so the picker dropdown reflects
  /// the selection immediately when the user changes it (the parent
  /// setState that updates the device doesn't rebuild this modal).
  late String? _selectedKeymap = widget.currentKeymap;

  @override
  void initState() {
    super.initState();
    widget.micMuted?.addListener(_onMicMute);
    // Pull live device state on every open so what's shown matches reality
    // (especially when the user toggled jiggler/power outside the app).
    _refreshAtx();
    _refreshJiggler();
    _refreshKeymaps();
  }

  @override
  void dispose() {
    widget.micMuted?.removeListener(_onMicMute);
    super.dispose();
  }

  void _onMicMute() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshAtx() async {
    if (!widget.client.supportsAtx) return;
    setState(() => _atxLoading = true);
    final s = await widget.client.readAtxState();
    if (!mounted) return;
    setState(() {
      _atx = s;
      _atxLoading = false;
    });
  }

  Future<void> _refreshJiggler() async {
    if (!widget.client.supportsJiggler) return;
    final v = await widget.client.readJiggler();
    if (!mounted) return;
    setState(() => _jigglerEnabled = v);
  }

  Future<void> _refreshKeymaps() async {
    if (!widget.client.supportsTextInput) {
      if (mounted) setState(() => _keymapsLoading = false);
      return;
    }
    final km = await widget.client.getKeymaps();
    if (!mounted) return;
    setState(() {
      _keymaps = km;
      _keymapsLoading = false;
    });
  }

  bool _allowed(_MenuAction a) =>
      widget.layout?.inPopup(a.name) ?? true;

  void _fire(_MenuAction a, {bool close = true}) {
    if (close) Navigator.of(context).maybePop();
    widget.onAction(a);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scroll) {
        return ListView(
          controller: scroll,
          padding: EdgeInsets.zero,
          children: [
            if (widget.client.supportsAtx) _powerHeader(),
            _section('Display', [
              if (_allowed(_MenuAction.toggleZoomLock))
                ListTile(
                  leading: Icon(widget.zoomLocked ? Icons.lock : Icons.lock_open),
                  title: Text(widget.zoomLocked ? 'Unlock zoom' : 'Lock zoom'),
                  onTap: () => _fire(_MenuAction.toggleZoomLock),
                ),
              if (_allowed(_MenuAction.rotate))
                ListTile(
                  leading: const Icon(Icons.screen_rotation),
                  title: const Text('Rotate device'),
                  onTap: () => _fire(_MenuAction.rotate),
                ),
              if (_allowed(_MenuAction.toggleFullscreen))
                ListTile(
                  leading: Icon(widget.fullscreen
                      ? Icons.fullscreen_exit
                      : Icons.fullscreen),
                  title: Text(widget.fullscreen ? 'Exit fullscreen' : 'Fullscreen'),
                  onTap: () => _fire(_MenuAction.toggleFullscreen),
                ),
              if (widget.supportsAbsolute &&
                  _allowed(_MenuAction.toggleAbsolutePointer))
                ListTile(
                  leading: Icon(widget.absolutePointer
                      ? Icons.touch_app
                      : Icons.mouse_outlined),
                  title: Text(widget.absolutePointer
                      ? 'Absolute pointer (on)'
                      : 'Absolute pointer (off)'),
                  onTap: () => _fire(_MenuAction.toggleAbsolutePointer),
                ),
              if (_allowed(_MenuAction.enterPip) && Platform.isAndroid)
                ListTile(
                  leading: const Icon(Icons.picture_in_picture_alt),
                  title: const Text('Picture in Picture'),
                  onTap: () => _fire(_MenuAction.enterPip),
                ),
              if (widget.client.supportsQualityControls &&
                  _allowed(_MenuAction.qualityControls))
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('Stream quality…'),
                  onTap: () => _fire(_MenuAction.qualityControls),
                ),
              if (_allowed(_MenuAction.streaming))
                ListTile(
                  leading: const Icon(Icons.cast_connected),
                  title: const Text('Streaming…'),
                  onTap: () => _fire(_MenuAction.streaming),
                ),
            ]),
            _section('Input', [
              if (_allowed(_MenuAction.nativeKeyboard))
                ListTile(
                  leading: Icon(widget.nativeKbVisible
                      ? Icons.keyboard_hide
                      : Icons.keyboard_alt_outlined),
                  title: Text(widget.nativeKbVisible
                      ? 'Hide native keyboard'
                      : 'Native keyboard'),
                  onTap: () => _fire(_MenuAction.nativeKeyboard),
                ),
              if (_allowed(_MenuAction.osKeyboard)) _oskRow(),
              if (_allowed(_MenuAction.keysOverlay)) _keysOverlayRow(),
              if (widget.client.supportsTextInput) _keymapRow(),
              if (_allowed(_MenuAction.specialKeys))
                ListTile(
                  leading: const Icon(Icons.bolt),
                  title: const Text('Special keys'),
                  onTap: () => _fire(_MenuAction.specialKeys),
                ),
            ]),
            _section('Hardware', [
              if (widget.client.supportsJiggler &&
                  _allowed(_MenuAction.toggleJiggler))
                SwitchListTile(
                  secondary: const Icon(Icons.directions_run),
                  title: const Text('Mouse jiggler'),
                  subtitle: Text(_jigglerEnabled == null
                      ? 'Reading device state…'
                      : (_jigglerEnabled! ? 'On' : 'Off')),
                  value: _jigglerEnabled ?? false,
                  onChanged: _jigglerEnabled == null
                      ? null
                      : (v) {
                          setState(() => _jigglerEnabled = v);
                          widget.onAction(_MenuAction.toggleJiggler);
                        },
                ),
              if (widget.hasMic && _allowed(_MenuAction.toggleMicMute))
                Builder(builder: (_) {
                  final muted = widget.micMuted?.value ?? false;
                  return ListTile(
                    leading: Icon(muted ? Icons.mic_off : Icons.mic),
                    title: Text(muted
                        ? 'Unmute microphone'
                        : 'Mute microphone'),
                    onTap: () =>
                        _fire(_MenuAction.toggleMicMute, close: false),
                  );
                }),
            ]),
            _section('Pointer sensitivity', [
              _sensitivityRow(
                Icons.mouse,
                'Mouse speed',
                _mouseSensitivity,
                onChanged: (v) {
                  setState(() => _mouseSensitivity = v);
                  widget.onMouseSensitivity(v);
                },
                onChangeEnd: (v) {
                  setState(() => _mouseSensitivity = v);
                  widget.onMouseSensitivity(v, persist: true);
                },
              ),
              _sensitivityRow(
                Icons.swipe_vertical,
                'Scroll speed',
                _scrollSensitivity,
                onChanged: (v) {
                  setState(() => _scrollSensitivity = v);
                  widget.onScrollSensitivity(v);
                },
                onChangeEnd: (v) {
                  setState(() => _scrollSensitivity = v);
                  widget.onScrollSensitivity(v, persist: true);
                },
              ),
            ]),
            _section('Session', [
              if (_allowed(_MenuAction.disconnect))
                ListTile(
                  leading: const Icon(Icons.power_settings_new),
                  title: const Text('Disconnect'),
                  onTap: () => _fire(_MenuAction.disconnect),
                ),
            ]),
            _section('Advanced', [
              SwitchListTile(
                secondary: const Icon(Icons.notes),
                title: const Text('Show connection log'),
                subtitle: const Text('Adds CPU cost while shown.'),
                value: _forceShowLog,
                onChanged: (v) {
                  setState(() => _forceShowLog = v);
                  widget.onAction(_MenuAction.showLog);
                },
              ),
              SwitchListTile(
                secondary: const Icon(Icons.bug_report_outlined),
                title: const Text('Show debug overlay'),
                subtitle: const Text('Live device + frame stats.'),
                value: _debugVisible,
                onChanged: (v) {
                  setState(() => _debugVisible = v);
                  widget.onAction(_MenuAction.toggleDebug);
                },
              ),
            ]),
            const SizedBox(height: 32),
          ],
        );
      },
    );
  }

  // ───── Section / power-header builders ───────────────────────────────────

  Widget _section(String title, List<Widget> rows) {
    final visible = rows.whereType<Widget>().toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        ...visible,
        const Divider(height: 24),
      ],
    );
  }

  Widget _powerHeader() {
    final on = _atx?.power;
    final color = on == null
        ? Colors.grey
        : (on ? Colors.greenAccent : Colors.grey.shade700);
    final label = _atxLoading
        ? 'Reading…'
        : (_atx == null
            ? 'Unknown'
            : (on == true ? 'On' : (on == false ? 'Off' : 'Unknown')));

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: ListTile(
          leading: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.25),
                    shape: BoxShape.circle),
              ),
              CircleAvatar(
                radius: 12,
                backgroundColor: color,
                child: Icon(
                  Icons.power_settings_new,
                  size: 14,
                  color: on == null ? Colors.white70 : Colors.black87,
                ),
              ),
            ],
          ),
          title: const Text('Power'),
          subtitle: Text(label),
          trailing: TextButton.icon(
            icon: const Icon(Icons.tune),
            label: const Text('Control…'),
            onPressed: () => _fire(_MenuAction.power),
          ),
        ),
      ),
    );
  }

  Widget _sensitivityRow(
    IconData icon,
    String label,
    double value, {
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 32),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(label)),
                    Text('${value.toStringAsFixed(1)}×'),
                  ],
                ),
                Slider(
                  min: 0.1,
                  max: 5.0,
                  divisions: 49,
                  value: value.clamp(0.1, 5.0),
                  onChanged: onChanged,
                  onChangeEnd: onChangeEnd,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Generic split-tap row: tapping the label closes the menu and pops the
  /// transparency adjuster for [target]; tapping the switch toggles whether
  /// the floating element is visible. Used for both the OSK and the
  /// keys-overlay so they share identical UX.
  Widget _floatingElementRow({
    required IconData iconOff,
    required IconData iconOn,
    required String labelOff,
    required String labelOn,
    required String secondary,
    required bool visible,
    required _TransparencyTarget target,
    required _MenuAction toggleAction,
  }) {
    return InkWell(
      onTap: () {
        Navigator.of(context).maybePop();
        widget.onTransparencyTap(target);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(visible ? iconOn : iconOff),
            const SizedBox(width: 32),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(visible ? labelOn : labelOff),
                  const SizedBox(height: 2),
                  Text(
                    secondary,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const SizedBox(
              height: 36,
              child: VerticalDivider(width: 1, thickness: 1),
            ),
            const SizedBox(width: 8),
            Switch(
              value: visible,
              onChanged: (_) {
                // Mirror locally so the switch state updates immediately;
                // the parent's setState on its own state field doesn't
                // rebuild this modal route.
                setState(() {
                  if (target == _TransparencyTarget.osk) {
                    _oskVisible = !_oskVisible;
                  } else {
                    _keysOverlayVisible = !_keysOverlayVisible;
                  }
                });
                widget.onAction(toggleAction);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _oskRow() => _floatingElementRow(
        iconOff: Icons.keyboard,
        iconOn: Icons.keyboard_hide,
        labelOff: 'On-screen keyboard',
        labelOn: 'Hide on-screen keyboard',
        secondary: _oskFloating
            ? 'Floating · tap label for transparency / dock'
            : 'Docked · tap label for transparency / float',
        visible: _oskVisible,
        target: _TransparencyTarget.osk,
        toggleAction: _MenuAction.osKeyboard,
      );

  /// Renders the device-side keymap selector. Subtitle shows the current
  /// selection (or "System default"). Tapping opens a SimpleDialog with
  /// every keymap the device's API reported. Selection persists onto the
  /// Device and immediately propagates to the OSK via the parent's
  /// derivation.
  Widget _keymapRow() {
    final loading = _keymapsLoading;
    final km = _keymaps;
    final cur = _selectedKeymap;
    String subtitle;
    if (loading) {
      subtitle = 'Loading available layouts…';
    } else if (km == null || km.available.isEmpty) {
      subtitle = 'Device default (no keymaps reported)';
    } else if (cur == null || cur.isEmpty) {
      subtitle = 'System default'
          '${km.defaultName.isEmpty ? '' : ' (${km.defaultName})'}';
    } else {
      subtitle = cur;
    }
    return ListTile(
      leading: const Icon(Icons.language),
      title: const Text('Keyboard layout'),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.arrow_drop_down),
      enabled: !loading && km != null && km.available.isNotEmpty,
      onTap: () async {
        if (loading || km == null || km.available.isEmpty) return;
        final picked = await showDialog<String?>(
          context: context,
          builder: (ctx) => _KeymapPickerDialog(
            current: cur,
            keymaps: km,
          ),
        );
        // The dialog returns the special sentinel `''` when the user
        // picks "System default", a non-empty string for an explicit
        // pick, or null when they cancel.
        if (picked == null) return;
        final next = picked.isEmpty ? null : picked;
        setState(() => _selectedKeymap = next);
        widget.onKeymapChanged(next);
      },
    );
  }

  Widget _keysOverlayRow() => _floatingElementRow(
        iconOff: Icons.keyboard_command_key,
        iconOn: Icons.keyboard_double_arrow_up,
        labelOff: 'Keys overlay',
        labelOn: 'Hide keys overlay',
        secondary:
            'F-keys + modifiers · tap label for transparency',
        visible: _keysOverlayVisible,
        target: _TransparencyTarget.keysOverlay,
        toggleAction: _MenuAction.keysOverlay,
      );
}

/// Bottom sheet exposing the device's stream-quality knobs (FPS, JPEG
/// quality, H.264 bitrate, GOP — whichever the device + mode supports).
/// Reads on open, writes on slider release.
class _QualitySheet extends StatefulWidget {
  final DeviceClient client;
  const _QualitySheet({required this.client});

  @override
  State<_QualitySheet> createState() => _QualitySheetState();
}

class _QualitySheetState extends State<_QualitySheet> {
  List<StreamQualityControl>? _controls;
  bool _loading = true;
  String? _error;
  final _saving = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final list = await widget.client.readStreamQuality();
    if (!mounted) return;
    setState(() {
      _controls = list;
      _loading = false;
      if (list == null || list.isEmpty) {
        _error = 'Device returned no stream-quality params.';
      }
    });
  }

  Future<void> _commit(StreamQualityControl c, double v) async {
    final rounded = (v / c.step).round() * c.step;
    setState(() {
      _saving[c.key] = true;
      // Optimistic local update so the slider stays where the user dropped it.
      final i = _controls!.indexWhere((x) => x.key == c.key);
      if (i >= 0) _controls![i] = _controls![i].copyWith(value: rounded);
    });
    final ok = await widget.client.setStreamQualityParam(c.key, rounded);
    if (!mounted) return;
    setState(() => _saving[c.key] = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not set ${c.label}.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (_, scroll) {
        return ListView(
          controller: scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.tune),
                const SizedBox(width: 8),
                const Text('Stream quality',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Reload from device',
                  onPressed: _loading ? null : _refresh,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else
              ..._controls!.map(_buildSlider),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }

  Widget _buildSlider(StreamQualityControl c) {
    final saving = _saving[c.key] == true;
    final divisions = ((c.max - c.min) / c.step).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(c.label)),
              if (saving)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  '${c.value.round()}${c.unit != null ? " ${c.unit}" : ""}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          Slider(
            min: c.min,
            max: c.max,
            divisions: divisions > 0 ? divisions : null,
            value: c.value.clamp(c.min, c.max),
            onChanged: (v) {
              setState(() {
                final i = _controls!.indexWhere((x) => x.key == c.key);
                if (i >= 0) _controls![i] = _controls![i].copyWith(value: v);
              });
            },
            onChangeEnd: (v) => _commit(c, v),
          ),
        ],
      ),
    );
  }
}

/// Streaming-mode + audio settings sheet. The mode picker lists what the
/// device-type supports today; audio toggles only render when WebRTC is
/// selected and the device type can carry audio (PiKVM only). Apply
/// triggers a reconnect so the client picks up the new mode.
/// Modal picker for the device-side keymap. Returns the chosen name on
/// pop ('' for "System default"), or null when cancelled.
class _KeymapPickerDialog extends StatelessWidget {
  final String? current;
  final HostKeymaps keymaps;
  const _KeymapPickerDialog({required this.current, required this.keymaps});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 480, maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.language),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text('Keyboard layout',
                        style: theme.textTheme.titleLarge),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  RadioListTile<String>(
                    value: '',
                    groupValue: current ?? '',
                    title: const Text('System default'),
                    subtitle: keymaps.defaultName.isEmpty
                        ? null
                        : Text(keymaps.defaultName),
                    onChanged: (v) => Navigator.of(context).pop(v),
                  ),
                  for (final name in keymaps.available)
                    if (name.isNotEmpty)
                      RadioListTile<String>(
                        value: name,
                        groupValue: current ?? '',
                        title: Text(name),
                        onChanged: (v) => Navigator.of(context).pop(v),
                      ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StreamingSheet extends StatefulWidget {
  final Device device;
  final Future<void> Function({
    required ConnectionMode mode,
    required bool audioRx,
    required bool micTx,
    String? micDeviceId,
    String? audioSinkId,
  }) onApply;
  // Video-fit changes don't require a reconnect (it's a pure UI sizing
  // tweak), so we expose them as a live callback rather than bundling
  // them into onApply's apply-and-reconnect path.
  final VideoFit currentVideoFit;
  final ValueChanged<VideoFit> onVideoFit;
  const _StreamingSheet({
    required this.device,
    required this.onApply,
    required this.currentVideoFit,
    required this.onVideoFit,
  });

  @override
  State<_StreamingSheet> createState() => _StreamingSheetState();
}

class _StreamingSheetState extends State<_StreamingSheet> {
  late ConnectionMode _mode = widget.device.mode;
  late bool _audioRx = widget.device.webrtcAudioRx;
  late bool _micTx = widget.device.webrtcMicTx;
  late String? _micDeviceId = widget.device.micDeviceId;
  late String? _audioSinkId = widget.device.audioSinkId;
  late VideoFit _videoFit = widget.currentVideoFit;
  bool _busy = false;

  /// Discovered audio inputs. Null while loading; empty/single-element when
  /// loaded but the picker should stay hidden.
  List<MediaDeviceInfo>? _audioInputs;

  /// Discovered audio outputs (sinks). Same null/empty semantics as above.
  List<MediaDeviceInfo>? _audioOutputs;

  bool get _supportsAudio =>
      widget.device.type == DeviceType.pikvm &&
      _mode == ConnectionMode.webrtc;

  bool _modeSupported(ConnectionMode m) {
    switch (m) {
      case ConnectionMode.mjpeg:
        return true;
      case ConnectionMode.webrtc:
        return true;
      case ConnectionMode.h264:
        return false;
    }
  }

  @override
  void initState() {
    super.initState();
    // Enumerate up front so the dropdown is ready when the user flips on
    // Send mic audio. Failure is silent — no picker is harmless, the OS
    // default still works.
    _refreshAudioInputs();
  }

  List<MediaDeviceInfo> _dedupByDeviceId(Iterable<MediaDeviceInfo> src) {
    final seen = <String>{};
    final out = <MediaDeviceInfo>[];
    for (final d in src) {
      if (seen.add(d.deviceId)) out.add(d);
    }
    return List.unmodifiable(out);
  }

  Future<void> _refreshAudioInputs() async {
    try {
      final devs = await navigator.mediaDevices.enumerateDevices();
      if (!mounted) return;
      // De-dup by deviceId. flutter_webrtc's Android implementation can
      // emit colliding ids (e.g. two built-in mics both reported as
      // "microphone-" because getAddress() is empty on SDK<P, or two
      // BluetoothHeadset entries both labelled "bluetooth"). Two
      // DropdownMenuItems with the same value crash the dialog the
      // moment that value is selected — Flutter's DropdownButton
      // asserts exactly-one-item-per-value.
      final inputs = _dedupByDeviceId(
        devs.where((d) => d.kind == 'audioinput'),
      );
      final outputs = _dedupByDeviceId(
        devs.where((d) => d.kind == 'audiooutput'),
      );
      setState(() {
        _audioInputs = inputs;
        _audioOutputs = outputs;
        // Drop stale selections when the device is no longer present, so
        // we don't try to acquire/route through something that vanished
        // since the user last picked it.
        if (_micDeviceId != null &&
            !inputs.any((d) => d.deviceId == _micDeviceId)) {
          _micDeviceId = null;
        }
        if (_audioSinkId != null &&
            !outputs.any((d) => d.deviceId == _audioSinkId)) {
          _audioSinkId = null;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _audioInputs = const [];
          _audioOutputs = const [];
        });
      }
    }
  }

  Future<void> _apply() async {
    setState(() => _busy = true);
    final mode = _mode;
    final audio = _supportsAudio ? _audioRx : false;
    final mic = _supportsAudio ? _micTx : false;
    await widget.onApply(
      mode: mode,
      audioRx: audio,
      micTx: mic,
      micDeviceId: mic ? _micDeviceId : null,
      audioSinkId: audio ? _audioSinkId : null,
    );
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    // Wrap the body in a SingleChildScrollView so the sheet stays usable
    // in landscape, where content (mode radios + fit toggle + audio
    // switches + mic/speaker dropdowns) can exceed the sheet's height.
    // Outer SafeArea + horizontal padding stay; the scroll view is the
    // direct parent of the previously-overflowing Column.
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cast_connected),
                const SizedBox(width: 8),
                const Text(
                  'Streaming',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Connection mode',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
              ),
            ),
            for (final m in ConnectionMode.values)
              if (_modeSupported(m))
                RadioListTile<ConnectionMode>(
                  contentPadding: EdgeInsets.zero,
                  value: m,
                  groupValue: _mode,
                  title: Text(m.label),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _mode = v ?? _mode),
                ),
            // Video fit. Live-applied (no reconnect) — _videoBoxKey
            // re-measures, TouchPointer adapts on the next pointer event.
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
              child: Row(
                children: [
                  Text(
                    'Video fit',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const Spacer(),
                  SegmentedButton<VideoFit>(
                    segments: const [
                      ButtonSegment(
                        value: VideoFit.stretch,
                        label: Text('Stretch'),
                        icon: Icon(Icons.fit_screen),
                      ),
                      ButtonSegment(
                        value: VideoFit.contain,
                        label: Text('Contain'),
                        icon: Icon(Icons.aspect_ratio),
                      ),
                    ],
                    selected: {_videoFit},
                    showSelectedIcon: false,
                    onSelectionChanged: _busy
                        ? null
                        : (s) {
                            final next = s.first;
                            setState(() => _videoFit = next);
                            widget.onVideoFit(next);
                          },
                  ),
                ],
              ),
            ),
            if (_supportsAudio) ...[
              const Divider(),
              Text(
                'Audio (PiKVM + WebRTC)',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Receive audio (PiKVM speaker out)'),
                value: _audioRx,
                onChanged: _busy
                    ? null
                    : (v) => setState(() {
                          _audioRx = v;
                          if (!v) _micTx = false; // mic without rx is moot
                        }),
              ),
              if (_audioRx &&
                  _audioOutputs != null &&
                  _audioOutputs!.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.speaker, size: 18),
                      const SizedBox(width: 8),
                      const Text('Output'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<String?>(
                          value: _audioSinkId,
                          isExpanded: true,
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('System default'),
                            ),
                            for (final d in _audioOutputs!)
                              DropdownMenuItem<String?>(
                                value: d.deviceId,
                                child: Text(
                                  d.label.isEmpty
                                      ? 'Output ${d.deviceId.substring(
                                          0,
                                          d.deviceId.length.clamp(0, 6),
                                        )}'
                                      : d.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _audioSinkId = v),
                        ),
                      ),
                    ],
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send mic audio'),
                value: _micTx,
                onChanged: _busy || !_audioRx
                    ? null
                    : (v) => setState(() => _micTx = v),
              ),
              // Only render the picker when there's an actual choice — for
              // a single mic the OS default is the correct answer.
              if (_micTx &&
                  _audioInputs != null &&
                  _audioInputs!.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Row(
                    children: [
                      const Icon(Icons.mic, size: 18),
                      const SizedBox(width: 8),
                      const Text('Mic source'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButton<String?>(
                          value: _micDeviceId,
                          isExpanded: true,
                          // Empty-string sentinel for "system default" —
                          // null isn't a valid DropdownMenuItem value when
                          // any other item carries a non-null value.
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('System default'),
                            ),
                            for (final d in _audioInputs!)
                              DropdownMenuItem<String?>(
                                value: d.deviceId,
                                child: Text(
                                  d.label.isEmpty
                                      ? 'Mic ${d.deviceId.substring(
                                          0,
                                          d.deviceId.length.clamp(0, 6),
                                        )}'
                                      : d.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: _busy
                              ? null
                              : (v) => setState(() => _micDeviceId = v),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed:
                      _busy ? null : () => Navigator.of(context).maybePop(),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Apply & reconnect'),
                  onPressed: _busy ? null : _apply,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact, non-modal floating bar that adjusts the opacity of one of the
/// two transparency-aware overlays (OSK / keys-overlay). Shown after the
/// user taps a row label in the menu sheet. Draggable so it never sits on
/// top of the thing being adjusted; closes via the × button.
class _TransparencyAdjuster extends StatefulWidget {
  final _TransparencyTarget target;
  final double opacity;
  final bool oskFloating;
  final ValueChanged<double> onOpacity;
  final VoidCallback onOpacityCommit;
  final VoidCallback onToggleDocked;
  final VoidCallback onClose;
  const _TransparencyAdjuster({
    required this.target,
    required this.opacity,
    required this.oskFloating,
    required this.onOpacity,
    required this.onOpacityCommit,
    required this.onToggleDocked,
    required this.onClose,
  });

  @override
  State<_TransparencyAdjuster> createState() =>
      _TransparencyAdjusterState();
}

class _TransparencyAdjusterState extends State<_TransparencyAdjuster> {
  Offset? _pos;

  static const _width = 320.0;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    _pos ??= Offset(
      ((screen.width - _width) / 2).clamp(0.0, screen.width).toDouble(),
      // OSK lives at the bottom by default — place the bar near the top so
      // it doesn't overlap. Keys-overlay sits at the top, so place this
      // bar a bit lower (still avoiding the bar itself).
      widget.target == _TransparencyTarget.osk
          ? padding.top + 12
          : padding.top + 70,
    );
    final isOsk = widget.target == _TransparencyTarget.osk;
    return Positioned(
      left: _pos!.dx,
      top: _pos!.dy,
      width: _width,
      child: Material(
        color: const Color.fromARGB(235, 24, 24, 24),
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GestureDetector(
                onPanUpdate: (d) => setState(() {
                  _pos = Offset(
                    (_pos!.dx + d.delta.dx)
                        .clamp(0.0, screen.width - _width),
                    (_pos!.dy + d.delta.dy)
                        .clamp(0.0, screen.height - 160),
                  );
                }),
                child: Row(
                  children: [
                    const Icon(Icons.drag_indicator,
                        size: 18, color: Colors.white54),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        isOsk
                            ? 'On-screen keyboard'
                            : 'Keys overlay',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      color: Colors.white70,
                      visualDensity: VisualDensity.compact,
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  const Icon(Icons.opacity,
                      size: 16, color: Colors.white70),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Slider(
                      min: 0.3,
                      max: 1.0,
                      divisions: 14,
                      value: widget.opacity.clamp(0.3, 1.0),
                      label: '${(widget.opacity * 100).round()}%',
                      onChanged: widget.onOpacity,
                      onChangeEnd: (_) => widget.onOpacityCommit(),
                    ),
                  ),
                  SizedBox(
                    width: 38,
                    child: Text(
                      '${(widget.opacity * 100).round()}%',
                      textAlign: TextAlign.right,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ],
              ),
              if (isOsk) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      const Text(
                        'Mode',
                        style: TextStyle(color: Colors.white70),
                      ),
                      const Spacer(),
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(
                            value: false,
                            label: Text('Docked'),
                            icon: Icon(Icons.vertical_align_bottom),
                          ),
                          ButtonSegment(
                            value: true,
                            label: Text('Floating'),
                            icon: Icon(Icons.open_with),
                          ),
                        ],
                        selected: {widget.oskFloating},
                        showSelectedIcon: false,
                        onSelectionChanged: (s) {
                          if (s.first != widget.oskFloating) {
                            widget.onToggleDocked();
                          }
                        },
                      ),
                    ],
                  ),
                ),
                // Layout used to live here as a QWERTY/AZERTY dropdown,
                // but it's now driven by the device-side keymap picker
                // in the popup menu (Input section → Keyboard layout).
                // OSK label rendering follows that selection automatically.
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Re-auth prompt shown when [DeviceClient.connect] throws [AuthException].
/// Saves the new credentials before popping `true` so the caller can just
/// retry the connection without further plumbing.
class _AuthDialog extends StatefulWidget {
  final Device device;
  const _AuthDialog({required this.device});

  @override
  State<_AuthDialog> createState() => _AuthDialogState();
}

class _AuthDialogState extends State<_AuthDialog> {
  late final TextEditingController _user =
      TextEditingController(text: widget.device.username ?? 'admin');
  final TextEditingController _pass = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final u = _user.text.trim();
    final p = _pass.text;
    if (u.isEmpty || p.isEmpty) return;
    setState(() => _busy = true);
    widget.device.username = u;
    await CredentialStore.setPassword(widget.device.id, p);
    if (mounted) {
      // Persist the username change too — credentials are in secure storage,
      // but the username lives on the Device object.
      context.read<DeviceStore>().update(widget.device);
    }
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Sign in to ${widget.device.name}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'The device rejected the saved credentials. Enter new ones to retry.',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: 'Username'),
            autofocus: false,
            enabled: !_busy,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pass,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            autofocus: true,
            onSubmitted: (_) => _submit(),
            enabled: !_busy,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Retry'),
        ),
      ],
    );
  }
}

class _AtxSheet extends StatelessWidget {
  final DeviceClient client;
  const _AtxSheet({required this.client});

  Future<void> _press(BuildContext context, AtxButton button) async {
    Navigator.of(context).pop();
    final ok = await client.pressAtx(button);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text(ok
          ? 'ATX: ${button.name} sent'
          : 'ATX: device rejected ${button.name}'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.power_settings_new),
              title: const Text('Power (short press)'),
              subtitle: const Text('Soft shutdown / wake'),
              onTap: () => _press(context, AtxButton.powerShort),
            ),
            ListTile(
              leading: const Icon(Icons.power_off),
              title: const Text('Force shutdown (5 s hold)'),
              subtitle: const Text('Hard power-off — data loss possible'),
              onTap: () => _press(context, AtxButton.powerLong),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt),
              title: const Text('Reset'),
              subtitle: const Text('Hardware reset'),
              onTap: () => _press(context, AtxButton.reset),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpecialKeysSheet extends StatelessWidget {
  final DeviceClient client;
  const _SpecialKeysSheet({required this.client});

  Future<void> _combo(List<String> codes) async {
    for (final c in codes) {
      await client.sendKey(code: c, down: true);
    }
    await Future.delayed(const Duration(milliseconds: 30));
    for (final c in codes.reversed) {
      await client.sendKey(code: c, down: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final btn = (String label, List<String> codes) => Padding(
          padding: const EdgeInsets.all(4),
          child: OutlinedButton(
            onPressed: () => _combo(codes),
            child: Text(label),
          ),
        );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Wrap(
        children: [
          btn('Ctrl+Alt+Del', ['ControlLeft', 'AltLeft', 'Delete']),
          btn('Win', ['MetaLeft']),
          btn('Esc', ['Escape']),
          btn('Tab', ['Tab']),
          btn('PrtSc', ['PrintScreen']),
          for (var i = 1; i <= 12; i++) btn('F$i', ['F$i']),
          btn('Alt+F4', ['AltLeft', 'F4']),
          btn('Ctrl+Shift+Esc', ['ControlLeft', 'ShiftLeft', 'Escape']),
        ],
      ),
    );
  }
}

class _DebugOverlay extends StatelessWidget {
  final Device device;
  final DeviceClient client;
  final Uint8List? frame;
  final VoidCallback onClose;
  const _DebugOverlay({
    required this.device,
    required this.client,
    required this.frame,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = device.useHttps ? 'https' : 'http';
    final lines = <String>[
      'device  ${device.name} (${device.type.label})',
      'host    $scheme://${device.host}',
      'mode    ${device.mode.label}',
      'state   ${client.state.value.name}',
      if (frame != null) 'frame   ${frame!.length} B',
    ];
    return Positioned(
      right: 12,
      bottom: 12,
      child: Material(
        elevation: 4,
        color: const Color.fromARGB(192, 0, 0, 0),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: lines
                    .map((l) => Text(
                          l,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ))
                    .toList(),
              ),
              IconButton(
                icon:
                    const Icon(Icons.close, color: Colors.white70, size: 16),
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
