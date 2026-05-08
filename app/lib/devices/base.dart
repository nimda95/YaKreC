import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../log/logger.dart';
import '../models/device.dart';
import '../transport/mjpeg.dart';

enum LinkState { idle, connecting, connected, errored, disconnected }

abstract class DeviceClient {
  final Device device;
  final Logger logger;

  DeviceClient(this.device, this.logger);

  ValueNotifier<LinkState> get state;

  /// JPEG frame stream when [Device.mode] is MJPEG; null otherwise.
  Stream<MjpegFrame>? get mjpegFrames;

  /// Live video renderer when [Device.mode] is WebRTC or H264; null otherwise.
  /// The client owns the renderer's lifecycle.
  RTCVideoRenderer? get videoRenderer => null;

  /// Mic-mute state for clients that capture local audio. Null when there's
  /// no mic in play (no WebRTC mic, or device doesn't support send-side
  /// audio). The UI shows a mute toggle iff this is non-null.
  ValueListenable<bool>? get micMuted => null;
  Future<void> setMicMuted(bool muted) async {}

  /// Live keyboard LED state from the host. Currently only PiKVM ships
  /// hid_state events that include caps/num/scroll lock; null on devices
  /// that don't surface it. The keys-overlay UI uses this to drive a
  /// device-synced Caps Lock indicator.
  ValueListenable<KeyboardLeds>? get keyboardLeds => null;

  // ───── Absolute mouse support ────────────────────────────────────────────

  /// Whether this client can drive an absolute-mode HID mouse. PiKVM/kvmd
  /// supports both absolute and relative; NanoKVM accepts both wire formats
  /// directly. Defaults false so the menu doesn't expose the option for
  /// devices that don't.
  bool get supportsAbsoluteMouse => false;

  /// Switches the underlying HID device into (or out of) absolute-coordinate
  /// mode. May be a no-op for devices that accept both formats over the same
  /// transport (NanoKVM); some (PiKVM) need an actual API call. Returns true
  /// on success.
  Future<bool> setAbsoluteMode(bool absolute) async => false;

  /// Native resolution of the host video. Used by [TouchPointer] to map
  /// pointer positions to absolute mouse coordinates with letterbox
  /// awareness. May be null if the device hasn't told us yet (e.g. waiting
  /// on the first WebRTC frame).
  Size? get hostVideoSize => null;

  Future<void> connect();
  Future<void> disconnect();

  Future<void> sendKey({required String code, required bool down}) async {}

  /// Whether the client can send a string of characters and let the device
  /// translate it to physical key sequences using its configured keymap.
  /// PiKVM's `/api/hid/print` does this; NanoKVM has no equivalent today.
  /// When true, the native-keyboard path forwards every printable batch
  /// through [sendText] so layout mismatches between the user's local
  /// keyboard and the host disappear (aVNC handles this implicitly via
  /// VNC keysyms — we lean on kvmd's keymap to do the same).
  bool get supportsTextInput => false;

  /// Sends [text] as if typed on the host's keyboard. Returns true on
  /// success (the device confirmed it consumed the text). False forces
  /// callers to fall back to per-character [sendKey] translation.
  Future<bool> sendText(String text) async => false;

  /// Available keymap names + the one the device currently treats as
  /// default. The UI uses this to render a picker in the connect-page
  /// popup so the user can match the host's layout (e.g. `en-us`,
  /// `fr-fr`, `de-de`). Returns null when the device doesn't expose
  /// keymap selection at all.
  Future<HostKeymaps?> getKeymaps() async => null;
  Future<void> sendMouseAbs(double normX, double normY) async {}
  Future<void> sendMouseRel(double dx, double dy) async {}
  Future<void> sendMouseButton(MouseButton button, bool down) async {}
  Future<void> sendMouseWheel(double dx, double dy) async {}

  /// Soft-pause the inbound video — flips the receiver track's `enabled`
  /// flag so the decoder stops working. Bandwidth-savings would need
  /// server-side renegotiation (TODO); this only saves CPU/battery.
  /// Audio + mic are intentionally untouched.
  Future<void> pauseVideo() async {}
  Future<void> resumeVideo() async {}

  // ───── Mouse jiggler ─────────────────────────────────────────────────────

  /// Whether this device exposes a mouse-jiggler API.
  bool get supportsJiggler => false;

  /// Reads the current jiggler enabled flag from the device. Returns null
  /// when unsupported or when the read fails.
  Future<bool?> readJiggler() async => null;

  /// Toggles the jiggler. Returns the new state on success, null on
  /// failure (no change applied or read-back disagreed).
  Future<bool?> setJiggler(bool enabled) async => null;

  // ───── ATX (power / reset over the device's iLO-style relay) ─────────────

  /// Whether this device exposes ATX power / reset controls.
  bool get supportsAtx => false;

  /// Triggers an ATX button press. Returns true on success.
  Future<bool> pressAtx(AtxButton button) async => false;

  /// Reads the live ATX LED state from the device. Null = unsupported or
  /// failed to read.
  Future<AtxState?> readAtxState() async => null;

  // ───── Streaming-quality controls ───────────────────────────────────────

  /// Whether this device exposes stream-quality controls (quality / fps /
  /// bitrate). When false the menu hides the section.
  bool get supportsQualityControls => false;

  /// Reads the device's current stream quality params, filtered by the
  /// active connection mode. Null on unsupported / read failure.
  Future<List<StreamQualityControl>?> readStreamQuality() async => null;

  /// Pushes a single param change to the device. Returns true on success.
  Future<bool> setStreamQualityParam(String key, num value) async => false;
}

/// Logical power-button actions, mapped to each device's wire format.
///   * [powerShort]  — short press; soft shutdown / wake on most hosts.
///   * [powerLong]   — long hold (~5 s); forced shutdown.
///   * [reset]       — reset button press.
enum AtxButton { powerShort, powerLong, reset }

/// Set of keymaps the device's text-input pipeline can translate against
/// + the one it considers the system default. Returned by
/// [DeviceClient.getKeymaps]; the UI uses it to render a picker.
class HostKeymaps {
  /// Name the device treats as the system default. The UI picker shows
  /// this as "System default" when the user hasn't overridden it. Empty
  /// string is allowed (NanoKVM uses it as the base US-map sentinel).
  final String defaultName;
  final List<String> available;
  const HostKeymaps({
    required this.defaultName,
    required this.available,
  });
}

/// Snapshot of the host's ATX LEDs. Either field may be null when the
/// device doesn't expose it.
class AtxState {
  final bool? power;
  final bool? hdd;
  const AtxState({this.power, this.hdd});
}

/// Snapshot of the host keyboard's lock LEDs. Booleans default to false so
/// the UI can light up the indicator only on a real "true" reading.
class KeyboardLeds {
  final bool capsLock;
  final bool numLock;
  final bool scrollLock;
  const KeyboardLeds({
    this.capsLock = false,
    this.numLock = false,
    this.scrollLock = false,
  });

  @override
  bool operator ==(Object other) =>
      other is KeyboardLeds &&
      other.capsLock == capsLock &&
      other.numLock == numLock &&
      other.scrollLock == scrollLock;

  @override
  int get hashCode => Object.hash(capsLock, numLock, scrollLock);
}

/// One stream-quality knob exposed to the UI.
///   * [key]   — wire-format param name; opaque to the UI.
///   * [label] — human-readable.
///   * [value] / [min] / [max] / [step] / [unit] — used to render a slider.
class StreamQualityControl {
  final String key;
  final String label;
  final double value;
  final double min;
  final double max;
  final double step;
  final String? unit;
  const StreamQualityControl({
    required this.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    this.step = 1,
    this.unit,
  });

  StreamQualityControl copyWith({double? value}) => StreamQualityControl(
        key: key,
        label: label,
        value: value ?? this.value,
        min: min,
        max: max,
        step: step,
        unit: unit,
      );
}

enum MouseButton { left, middle, right, up, down }

/// Thrown by device clients when the credentials are rejected. Lets
/// [ConnectPage] detect the failure case specifically and prompt for new
/// credentials instead of falling into the generic error log view.
class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => 'Authentication failed: $message';
}
