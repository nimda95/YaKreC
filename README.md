# YaKreC

**Yet Another Kvm REmote Client.** A Flutter-based KVM-over-IP client for
[PiKVM](https://pikvm.org) and [Sipeed NanoKVM](https://wiki.sipeed.com/nanokvm),
targeting **Android** and **Linux desktop**. Web is intentionally not
supported — the project leans on platform-specific HID, multicast DNS, and
WebRTC paths that aren't web-portable.

The project is named after how it started: there are already several KVM
clients out there, this is yet another one — but with a focus on first-class
PiKVM + NanoKVM support, true multi-touch on-screen controls, and proper
desktop ergonomics (window fullscreen, key capture, audio sink selection)
alongside the mobile flow.

## What works today

**Streaming**
- MJPEG and **WebRTC** for PiKVM (with optional 2-way audio via Janus).
- MJPEG (and direct H.264 over WS) for Sipeed NanoKVM.
- Per-device fit toggle: stretch-to-fill (max visibility, mild distortion
  on aspect mismatch) or contain (preserve aspect, letterbox bars).
  Touch accuracy is preserved in both modes — pointer math reads the
  *actual* rendered video rect, not an inferred BoxFit guess.

**Input**
- Hardware keyboard capture via `HardwareKeyboard.instance` — every
  non-OS-reserved key reaches the host regardless of focus.
- Multi-touch on-screen keyboard (QWERTY/AZERTY layouts, label-aware
  Shift / AltGr) and a floating "common keys" bar (F1-F12, modifiers
  with sticky-on-tap, arrows, Esc/Del). Hold modifiers with one finger
  and tap target keys with another for real Ctrl+Alt+Del.
- Caps Lock indicator synced with the host's keyboard LED state.
- Per-device keymap selector populated from the device's own API
  (`GET /api/hid/keymaps` for PiKVM; hardcoded `[base, de, fr]` for
  NanoKVM). Typed text routes through `/api/hid/print` (PiKVM) or
  `/api/hid/paste` (NanoKVM) so server-side translation handles whatever
  IME / language the user has on their phone.
- Mouse and S-Pen with both **trackpad** (relative) and **touchscreen**
  (absolute) modes. Pinch-zoom locked off in absolute mode so pointer
  math stays exact.

**Audio**
- 2-way audio on PiKVM WebRTC (receive + mic).
- Mic input source picker when more than one input is present.
- Audio output sink picker when more than one output is present.

**Misc**
- mDNS / `.local` hostname resolution with an explanatory permission
  pre-prompt on Android 13+ (Nearby Wi-Fi Devices).
- Linux fullscreen hides the GTK header bar (via a method channel into
  the C++ runner).
- Per-device persistence of every meaningful UI choice: video fit,
  rotation, fullscreen, OSK floating + position + opacity, keys-overlay
  visibility + position + opacity, absolute-pointer mode, zoom lock,
  keymap, mic + audio device IDs, mouse + scroll sensitivity.
- Light / dark / system theme switcher in the home drawer.
- Stream-quality controls (FPS, JPEG quality, GOP, bitrate where
  exposed) with persistence on NanoKVM (the device has no GET endpoint;
  we mirror the official web UI's localStorage trick).
- Mouse jiggler, ATX power short / long / reset (PiKVM).

## Build

All builds run inside Docker. Nothing gets installed on the host.

```bash
./scripts/build.sh --target=apk                    # build/dist/kvm.apk (release)
./scripts/build.sh --target=apk --mode=debug       # build/dist/kvm-debug.apk (faster)
./scripts/build.sh --target=appimage               # build/dist/kvm-x86_64.AppImage
./scripts/build.sh --target=appimage --mode=debug
```

Use `--mode=debug` for fast dev iteration — skips AOT, skips R8 shrinking,
signs with a persistent debug keystore so update-installs still work.

The first invocation builds the Docker image (~3 GB: Flutter SDK + Android
SDK + GTK toolchain + appimagetool). Subsequent builds reuse it.

### Caches

| What | Where | Notes |
|---|---|---|
| Docker image | `kvm-builder:latest` | Rebuilt only if missing |
| Pub packages | `~/.cache/kvm/pub` | Bind-mounted into the container |
| Gradle deps | `~/.cache/kvm/gradle` | Bind-mounted into the container |
| Android SDK | `~/.cache/kvm/android-sdk` | Seeded from the image on first run |
| Android user dir | `~/.cache/kvm/android-user` | `debug.keystore`, build cache |
| Release keystore | `~/.cache/kvm/keystore/release.jks` | Generated once; reused so signatures stay stable |
| Flutter incremental | `app/build/`, `app/.dart_tool/` | Persists via the workspace mount |

Override the cache root with `KVM_CACHE_DIR=/some/path`. Cache contents
are written by root inside the container; to wipe: `sudo rm -rf ~/.cache/kvm`.

## Project layout

| Path | Purpose |
|---|---|
| `app/` | Flutter project |
| `app/lib/devices/{pikvm,nanokvm}/` | Per-device clients (HTTP/WS, HID, WebRTC) |
| `app/lib/transport/mjpeg.dart` | Multipart MJPEG parser |
| `app/lib/input/{keyboard_capture,touch_pointer}.dart` | Key + pointer routing |
| `app/lib/net/mdns.dart` | `.local` resolver with NEARBY_WIFI_DEVICES gate |
| `app/lib/ui/` | Home, drawer, connect, on-screen keyboard, keys overlay |
| `app/lib/desktop/window_bridge.dart` | Linux GTK fullscreen method channel |
| `app/linux/runner/` | C++ runner (window icon, GTK fullscreen handler) |
| `docker/Dockerfile` | Build image (cirruslabs/flutter + Linux deps) |
| `scripts/build.sh` | One entry point for both targets |
| `scripts/bootstrap.sh` | One-time scaffold of platform folders |
| `.github/workflows/build.yml` | CI on a self-hosted Linux runner |

## Device setup

### PiKVM

- **Host**: `pikvm.local` (mDNS) or the IP. HTTPS by default with a
  self-signed cert — toggle "Accept self-signed certificates" on.
- **Credentials**: as configured in `kvmd` (default `admin` / `admin`).
- **Streaming**: MJPEG works out of the box; switch to WebRTC in the
  in-session menu for lower latency + audio.
- **Keymap**: pick the host's layout from the keyboard-layout entry in
  the popup menu (populated from `GET /api/hid/keymaps`). Required if
  your host isn't US-QWERTY.

### Sipeed NanoKVM

- **Host**: `kvm-nas.local` (or whatever you set in NanoKVM's web UI).
- **Credentials**: `admin` / your configured password.
- **Streaming**: MJPEG. The client matches NanoKVM's frontend exactly —
  AES-256-CBC + MD5 KDF with the hardcoded passphrase
  `nanokvm-sipeed-2024`, base64 + URL-encoded, posted as `password` to
  `/api/auth/login`.
- **Keymap**: only `base`, `de`, `fr` are supported by the current
  upstream `paste.go`; pick from the menu.

## Credits — third-party packages

YaKreC stands on the work of a lot of other open-source projects. Direct
runtime dependencies and their upstream licenses:

| Package | License | Used for |
|---|---|---|
| [flutter](https://flutter.dev) | BSD-3-Clause | UI framework |
| [shared_preferences](https://pub.dev/packages/shared_preferences) | BSD-3-Clause | UI / device-state persistence |
| [flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) | BSD-3-Clause | Per-device password storage |
| [http](https://pub.dev/packages/http) | BSD-3-Clause | HTTP client |
| [web_socket_channel](https://pub.dev/packages/web_socket_channel) | BSD-3-Clause | HID + Janus signaling WebSockets |
| [path_provider](https://pub.dev/packages/path_provider) | BSD-3-Clause | Log export path |
| [uuid](https://pub.dev/packages/uuid) | MIT | Per-device IDs |
| [provider](https://pub.dev/packages/provider) | MIT | Theme + device-store reactive bindings |
| [pointycastle](https://pub.dev/packages/pointycastle) | MIT-equivalent (BC) | NanoKVM CryptoJS-compat AES + MD5 KDF |
| [flutter_webrtc](https://pub.dev/packages/flutter_webrtc) | MIT | PiKVM WebRTC + 2-way audio |
| [multicast_dns](https://pub.dev/packages/multicast_dns) | BSD-3-Clause | `.local` hostname resolution |
| [permission_handler](https://pub.dev/packages/permission_handler) | MIT | NEARBY_WIFI_DEVICES runtime permission |
| [url_launcher](https://pub.dev/packages/url_launcher) | BSD-3-Clause | Donate / source-code links |

Beyond the Dart packages, the project relies on:

- The **PiKVM** project (`kvmd`, `ustreamer`, Janus) — without their
  HTTP / WebSocket / WebRTC API surface there'd be nothing to talk to.
  https://github.com/pikvm
- The **Sipeed NanoKVM** firmware — the in-tree handlers under
  `server/service/hid` and the web UI in `web/src/` were the reference
  for our text-input and stream paths. https://github.com/sipeed/NanoKVM
- **aVNC** by [@gujjwal00](https://github.com/gujjwal00) — reference
  for the home-page layout, the soft-keyboard newline plumbing, and the
  layout-aware text-input philosophy. https://github.com/gujjwal00/avnc
- **AppImageKit** for the Linux distribution format.
  https://github.com/AppImage/AppImageKit
- App icon: generated with [Icon Kitchen](https://icon.kitchen/).

## Contributing

PRs welcome. Please run `./scripts/build.sh --target=apk --mode=debug`
locally before opening a PR (the same command CI runs) so any source-
incompat surfaces before review.

If you want to port to iOS or macOS — the build script has no
scaffolding for either today, but `flutter create --platforms=ios,macos .`
inside `app/` would lay it down. The IconKitchen iOS asset set was
deliberately not committed; an iOS PR is the right time to add it.

## License

Source code is released under the MIT License. See `LICENSE` for the
full text.

The project's own assets (icons, screenshots) are under the MIT License
unless individual files note otherwise. Third-party packages keep their
upstream licenses listed above.

## Donate

If YaKreC saved you some hassle and you'd like to help cover hosting +
development time: <https://aymane.xyz/yakrec-donate.html>.

Source code: <https://github.com/nimda95/yakrec>.
