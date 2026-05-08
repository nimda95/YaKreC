import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../devices/base.dart';
import '../devices/pikvm/keymap.dart';

/// Forwards every hardware-keyboard event the app receives to the device.
///
/// We hook [HardwareKeyboard.instance] directly instead of routing through a
/// `Focus`/`onKeyEvent` callback for two reasons:
///   * `Focus` widgets that briefly steal focus (e.g. opening a sheet, a
///     dropdown, a slider thumb) would silently drop subsequent key events.
///   * Some keys — Tab, arrow keys, Space — are consumed by Flutter's
///     `DefaultFocusTraversal` / `DefaultTextEditingShortcuts` *before* a
///     `Focus.onKeyEvent` runs. The hardware-keyboard hook fires for every
///     physical key the platform delivers, regardless of focus or shortcuts.
///
/// On Android, OS-reserved keys (Home, Recents, Volume, Power) never reach
/// the engine, so they can't be captured here. Same story on Linux for
/// keys grabbed by the compositor / window manager (e.g. Super, Alt+F4 in
/// some setups). Everything else is forwarded.
class KeyboardCapture extends StatefulWidget {
  final DeviceClient client;
  final Widget child;
  final bool enabled;

  const KeyboardCapture({
    super.key,
    required this.client,
    required this.child,
    this.enabled = true,
  });

  @override
  State<KeyboardCapture> createState() => _KeyboardCaptureState();
}

class _KeyboardCaptureState extends State<KeyboardCapture> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent ev) {
    if (!widget.enabled) return false;
    final code = pikvmKeyCode(ev.physicalKey);
    if (code == null) return false;
    if (ev is KeyDownEvent) {
      widget.client.sendKey(code: code, down: true);
      return true;
    }
    if (ev is KeyUpEvent) {
      widget.client.sendKey(code: code, down: false);
      return true;
    }
    if (ev is KeyRepeatEvent) {
      // Forward repeats as fresh down events; the host's auto-repeat will
      // handle long-presses, but explicit repeats keep latency lower for
      // burst typing.
      widget.client.sendKey(code: code, down: true);
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
