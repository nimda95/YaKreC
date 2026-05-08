import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../ui/on_screen_keyboard.dart' show KeyboardLayout;

/// How the host video is sized inside the connect page's viewport.
///   * [stretch]: fill the whole viewport, distort if aspect doesn't match.
///   * [contain]: preserve the host's aspect, letterbox the rest.
/// Touch accuracy is identical for both: the connect page measures the
/// actual rendered SizedBox and reports its rect to the input layer.
enum VideoFit { stretch, contain }

/// Per-device UI preferences that survive across app launches: fullscreen
/// mode, OSK floating-vs-docked, screen rotation, and overlay opacities for
/// the on-screen keyboard and the floating keys bar. Kept separate from the
/// connection config (host, creds, mode) — those live in [DeviceStore].
class DeviceUiState {
  final bool fullscreen;
  final bool oskFloating;
  /// 0..3, mapping to portraitUp / landscapeRight / portraitDown / landscapeLeft.
  final int rotation;

  /// Whether the floating "common keys" overlay (F-keys, modifiers, arrows
  /// etc.) is visible. Persisted so it sticks across app restarts.
  final bool keysOverlayVisible;

  /// 0.30 .. 1.00. Applied as widget-level opacity to the keys bar.
  final double keysOverlayOpacity;

  /// 0.30 .. 1.00. Applied to the on-screen keyboard so it can be made
  /// see-through when docked at the bottom and covering half the host screen.
  final double oskOpacity;

  /// Display layout for the on-screen keyboard. The wire codes don't change
  /// — only the labels do — so the user picks whichever matches the host's
  /// configured layout.
  final KeyboardLayout oskLayout;

  /// How the host video sizes inside the viewport (stretch vs preserve
  /// aspect / letterbox). Default stretch maximises visibility.
  final VideoFit videoFit;

  /// Last drag position of the OSK floating panel. Null = use the widget's
  /// default centre-of-screen on next mount.
  final double? oskFloatX;
  final double? oskFloatY;

  /// Last vertical drag position of the keys-overlay bar. Bar is full-width
  /// so only Y is meaningful. Null = default top-of-safe-area placement.
  final double? keysOverlayY;

  /// Last visibility of the OSK; mirrors what [keysOverlayVisible] does
  /// for the other overlay so reopening the device restores the layout.
  final bool oskVisible;

  /// Pointer-mode toggle: false = trackpad / relative, true = absolute /
  /// touchscreen. Persisted because it's a workflow preference per host.
  final bool absolutePointer;

  /// Zoom lock state of the InteractiveViewer (true = pinch disabled in
  /// trackpad mode). Cosmetic; stored so the user doesn't have to flip it
  /// each reconnect.
  final bool zoomLocked;

  const DeviceUiState({
    this.fullscreen = false,
    this.oskFloating = false,
    this.rotation = 0,
    this.keysOverlayVisible = false,
    this.keysOverlayOpacity = 0.85,
    this.oskOpacity = 0.85,
    this.oskLayout = KeyboardLayout.qwerty,
    this.videoFit = VideoFit.stretch,
    this.oskFloatX,
    this.oskFloatY,
    this.keysOverlayY,
    this.oskVisible = false,
    this.absolutePointer = false,
    this.zoomLocked = false,
  });

  static const defaults = DeviceUiState();

  DeviceUiState copyWith({
    bool? fullscreen,
    bool? oskFloating,
    int? rotation,
    bool? keysOverlayVisible,
    double? keysOverlayOpacity,
    double? oskOpacity,
    KeyboardLayout? oskLayout,
    VideoFit? videoFit,
    double? oskFloatX,
    double? oskFloatY,
    double? keysOverlayY,
    bool? oskVisible,
    bool? absolutePointer,
    bool? zoomLocked,
  }) =>
      DeviceUiState(
        fullscreen: fullscreen ?? this.fullscreen,
        oskFloating: oskFloating ?? this.oskFloating,
        rotation: rotation ?? this.rotation,
        keysOverlayVisible: keysOverlayVisible ?? this.keysOverlayVisible,
        keysOverlayOpacity: keysOverlayOpacity ?? this.keysOverlayOpacity,
        oskOpacity: oskOpacity ?? this.oskOpacity,
        oskLayout: oskLayout ?? this.oskLayout,
        videoFit: videoFit ?? this.videoFit,
        oskFloatX: oskFloatX ?? this.oskFloatX,
        oskFloatY: oskFloatY ?? this.oskFloatY,
        keysOverlayY: keysOverlayY ?? this.keysOverlayY,
        oskVisible: oskVisible ?? this.oskVisible,
        absolutePointer: absolutePointer ?? this.absolutePointer,
        zoomLocked: zoomLocked ?? this.zoomLocked,
      );

  Map<String, dynamic> toJson() => {
        'fullscreen': fullscreen,
        'oskFloating': oskFloating,
        'rotation': rotation,
        'keysOverlayVisible': keysOverlayVisible,
        'keysOverlayOpacity': keysOverlayOpacity,
        'oskOpacity': oskOpacity,
        'oskLayout': oskLayout.name,
        'videoFit': videoFit.name,
        'oskFloatX': oskFloatX,
        'oskFloatY': oskFloatY,
        'keysOverlayY': keysOverlayY,
        'oskVisible': oskVisible,
        'absolutePointer': absolutePointer,
        'zoomLocked': zoomLocked,
      };

  factory DeviceUiState.fromJson(Map<String, dynamic> j) => DeviceUiState(
        fullscreen: j['fullscreen'] as bool? ?? false,
        oskFloating: j['oskFloating'] as bool? ?? false,
        rotation: ((j['rotation'] as num?)?.toInt() ?? 0) % 4,
        keysOverlayVisible: j['keysOverlayVisible'] as bool? ?? false,
        keysOverlayOpacity:
            ((j['keysOverlayOpacity'] as num?)?.toDouble() ?? 0.85)
                .clamp(0.3, 1.0)
                .toDouble(),
        oskOpacity: ((j['oskOpacity'] as num?)?.toDouble() ?? 0.85)
            .clamp(0.3, 1.0)
            .toDouble(),
        oskLayout: KeyboardLayout.values.firstWhere(
          (e) => e.name == (j['oskLayout'] as String?),
          orElse: () => KeyboardLayout.qwerty,
        ),
        videoFit: VideoFit.values.firstWhere(
          (e) => e.name == (j['videoFit'] as String?),
          orElse: () => VideoFit.stretch,
        ),
        oskFloatX: (j['oskFloatX'] as num?)?.toDouble(),
        oskFloatY: (j['oskFloatY'] as num?)?.toDouble(),
        keysOverlayY: (j['keysOverlayY'] as num?)?.toDouble(),
        oskVisible: j['oskVisible'] as bool? ?? false,
        absolutePointer: j['absolutePointer'] as bool? ?? false,
        zoomLocked: j['zoomLocked'] as bool? ?? false,
      );
}

class UiStateStore {
  static String _key(String deviceId) => 'kvm.uistate.$deviceId';

  static Future<DeviceUiState> load(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(deviceId));
    if (raw == null) return DeviceUiState.defaults;
    try {
      return DeviceUiState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return DeviceUiState.defaults;
    }
  }

  static Future<void> save(String deviceId, DeviceUiState state) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(deviceId), jsonEncode(state.toJson()));
  }

  static Future<void> clear(String deviceId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(deviceId));
  }
}
