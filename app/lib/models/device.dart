enum DeviceType { pikvm, nanokvm }

enum ConnectionMode { mjpeg, h264, webrtc }

extension DeviceTypeX on DeviceType {
  String get label => switch (this) {
        DeviceType.pikvm => 'PiKVM',
        DeviceType.nanokvm => 'Sipeed NanoKVM',
      };
}

extension ConnectionModeX on ConnectionMode {
  String get label => switch (this) {
        ConnectionMode.mjpeg => 'MJPEG',
        ConnectionMode.h264 => 'Direct H264',
        ConnectionMode.webrtc => 'WebRTC',
      };
}

/// A saved KVM device. Password is kept separately in CredentialStore,
/// keyed on [id], so this object is safe to serialize as plain JSON.
class Device {
  final String id;
  String name;
  DeviceType type;

  /// host[:port], no scheme. Combined with [useHttps] to form the base URI.
  String host;
  bool useHttps;
  bool acceptSelfSigned;

  ConnectionMode mode;

  /// Free-form headers added to every HTTP/WS request. One per line in the UI:
  /// `Header-Name: value`.
  Map<String, String> customHeaders;

  String? username;

  /// Only meaningful for [DeviceType.pikvm] + [ConnectionMode.webrtc].
  bool webrtcAudioRx;
  bool webrtcMicTx;

  /// Whether the mic track should start out muted on the next session. The
  /// runtime mute state (toggled via the connect-page menu / long-press)
  /// writes back here so the choice survives reconnects and app restarts.
  /// Only consulted when [webrtcMicTx] is on.
  bool micMuted;

  /// OS-level audio-input device id to capture when [webrtcMicTx] is on.
  /// Null = let the OS pick the default. Persisted so the choice survives
  /// reconnects and app restarts.
  String? micDeviceId;

  /// OS-level audio-output device id (sink) to route received PiKVM audio
  /// to when [webrtcAudioRx] is on. Null = system default.
  String? audioSinkId;

  /// Device-side keymap name used when translating typed text into HID
  /// scancodes (PiKVM `/api/hid/print?keymap=...`, NanoKVM
  /// `/api/hid/paste`'s `langue`). Null = use whatever the device treats
  /// as default. Picked from a per-device dropdown that's populated by
  /// the device's own keymaps API.
  String? keymap;

  /// Trackpad-mode sensitivity multipliers. 1.0 = identity. Applied to
  /// relative pointer deltas (mouseSensitivity) and wheel deltas
  /// (scrollSensitivity) on the touch-input path.
  double mouseSensitivity;
  double scrollSensitivity;

  Device({
    required this.id,
    required this.name,
    required this.type,
    required this.host,
    this.useHttps = true,
    this.acceptSelfSigned = false,
    this.mode = ConnectionMode.mjpeg,
    Map<String, String>? customHeaders,
    this.username,
    this.webrtcAudioRx = false,
    this.webrtcMicTx = false,
    this.micMuted = false,
    this.micDeviceId,
    this.audioSinkId,
    this.keymap,
    this.mouseSensitivity = 1.0,
    this.scrollSensitivity = 1.0,
  }) : customHeaders = customHeaders ?? {};

  /// Session-only override that wins over [host] when computing URIs. Set by
  /// the mDNS resolver after a successful `.local` lookup so the rest of the
  /// stack just talks to the cached IP without round-tripping through DNS.
  /// Not serialised — we only persist the user-typed [host].
  String? runtimeHost;

  String get effectiveHost => runtimeHost ?? host;

  Uri baseUri() =>
      Uri.parse('${useHttps ? 'https' : 'http'}://$effectiveHost');

  Uri wsBaseUri() =>
      Uri.parse('${useHttps ? 'wss' : 'ws'}://$effectiveHost');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'host': host,
        'useHttps': useHttps,
        'acceptSelfSigned': acceptSelfSigned,
        'mode': mode.name,
        'customHeaders': customHeaders,
        'username': username,
        'webrtcAudioRx': webrtcAudioRx,
        'webrtcMicTx': webrtcMicTx,
        'micMuted': micMuted,
        'micDeviceId': micDeviceId,
        'audioSinkId': audioSinkId,
        'keymap': keymap,
        'mouseSensitivity': mouseSensitivity,
        'scrollSensitivity': scrollSensitivity,
      };

  factory Device.fromJson(Map<String, dynamic> j) => Device(
        id: j['id'] as String,
        name: j['name'] as String,
        type: DeviceType.values.byName(j['type'] as String),
        host: j['host'] as String,
        useHttps: j['useHttps'] as bool? ?? true,
        acceptSelfSigned: j['acceptSelfSigned'] as bool? ?? false,
        mode: ConnectionMode.values
            .byName(j['mode'] as String? ?? 'mjpeg'),
        customHeaders: Map<String, String>.from(
            (j['customHeaders'] as Map?) ?? const {}),
        username: j['username'] as String?,
        webrtcAudioRx: j['webrtcAudioRx'] as bool? ?? false,
        webrtcMicTx: j['webrtcMicTx'] as bool? ?? false,
        micMuted: j['micMuted'] as bool? ?? false,
        micDeviceId: j['micDeviceId'] as String?,
        audioSinkId: j['audioSinkId'] as String?,
        keymap: j['keymap'] as String?,
        mouseSensitivity:
            (j['mouseSensitivity'] as num?)?.toDouble() ?? 1.0,
        scrollSensitivity:
            (j['scrollSensitivity'] as num?)?.toDouble() ?? 1.0,
      );
}
