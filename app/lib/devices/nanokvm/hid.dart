import 'dart:typed_data';

/// NanoKVM HID protocol over `/api/ws` (binary frames).
///
///   byte 0 : message type
///            1 = Keyboard, 2 = Mouse, 0 = Heartbeat
///   bytes 1..n: HID report
///
/// Keyboard payload is a USB HID Boot Keyboard Report (8 bytes):
///   modifier, reserved, key1, key2, key3, key4, key5, key6
///
/// Mouse (relative) payload is 4 bytes:
///   buttons, dx, dy, wheel (signed -127..127)
class NanoKvmMsg {
  static const keyboard = 1;
  static const mouse = 2;
  static const heartbeat = 0;
}

/// Tracks pressed keys + modifier bits and builds the 8-byte report.
class HidKeyboardState {
  int _modifier = 0;
  final List<int> _pressed = []; // insertion order, max 6

  /// Apply a key change. Returns the new 8-byte report, or null if [code]
  /// isn't recognized.
  Uint8List? apply({required String code, required bool down}) {
    final k = hidKeyTable[code];
    if (k == null) return null;
    if (k.modifierBit != null) {
      final mask = 1 << k.modifierBit!;
      if (down) {
        _modifier |= mask;
      } else {
        _modifier &= ~mask;
      }
    } else {
      final usage = k.usage!;
      if (down) {
        if (!_pressed.contains(usage)) {
          _pressed.add(usage);
          if (_pressed.length > 6) _pressed.removeAt(0);
        }
      } else {
        _pressed.remove(usage);
      }
    }
    return _build();
  }

  /// Release everything (Ctrl+Alt+Del style cleanup).
  Uint8List releaseAll() {
    _modifier = 0;
    _pressed.clear();
    return _build();
  }

  Uint8List _build() {
    final r = Uint8List(8);
    r[0] = _modifier;
    r[1] = 0;
    for (var i = 0; i < _pressed.length && i < 6; i++) {
      r[2 + i] = _pressed[i];
    }
    return r;
  }
}

class HidKey {
  final int? usage;
  final int? modifierBit;
  const HidKey.usage(this.usage) : modifierBit = null;
  const HidKey.modifier(this.modifierBit) : usage = null;
}

/// Map DOM-style key codes (the same ones [pikvmKeyCode] emits) to USB HID
/// usage codes / modifier bits. Keep in sync with the PiKVM keymap so the
/// hardware keyboard handler doesn't need to care which device is wired up.
const Map<String, HidKey> hidKeyTable = {
  // Modifiers
  'ControlLeft':  HidKey.modifier(0),
  'ShiftLeft':    HidKey.modifier(1),
  'AltLeft':      HidKey.modifier(2),
  'MetaLeft':     HidKey.modifier(3),
  'ControlRight': HidKey.modifier(4),
  'ShiftRight':   HidKey.modifier(5),
  'AltRight':     HidKey.modifier(6),
  'MetaRight':    HidKey.modifier(7),

  // Letters
  'KeyA': HidKey.usage(0x04), 'KeyB': HidKey.usage(0x05),
  'KeyC': HidKey.usage(0x06), 'KeyD': HidKey.usage(0x07),
  'KeyE': HidKey.usage(0x08), 'KeyF': HidKey.usage(0x09),
  'KeyG': HidKey.usage(0x0A), 'KeyH': HidKey.usage(0x0B),
  'KeyI': HidKey.usage(0x0C), 'KeyJ': HidKey.usage(0x0D),
  'KeyK': HidKey.usage(0x0E), 'KeyL': HidKey.usage(0x0F),
  'KeyM': HidKey.usage(0x10), 'KeyN': HidKey.usage(0x11),
  'KeyO': HidKey.usage(0x12), 'KeyP': HidKey.usage(0x13),
  'KeyQ': HidKey.usage(0x14), 'KeyR': HidKey.usage(0x15),
  'KeyS': HidKey.usage(0x16), 'KeyT': HidKey.usage(0x17),
  'KeyU': HidKey.usage(0x18), 'KeyV': HidKey.usage(0x19),
  'KeyW': HidKey.usage(0x1A), 'KeyX': HidKey.usage(0x1B),
  'KeyY': HidKey.usage(0x1C), 'KeyZ': HidKey.usage(0x1D),

  // Digits — HID orders 1..9 then 0
  'Digit1': HidKey.usage(0x1E), 'Digit2': HidKey.usage(0x1F),
  'Digit3': HidKey.usage(0x20), 'Digit4': HidKey.usage(0x21),
  'Digit5': HidKey.usage(0x22), 'Digit6': HidKey.usage(0x23),
  'Digit7': HidKey.usage(0x24), 'Digit8': HidKey.usage(0x25),
  'Digit9': HidKey.usage(0x26), 'Digit0': HidKey.usage(0x27),

  // Common
  'Enter':        HidKey.usage(0x28),
  'Escape':       HidKey.usage(0x29),
  'Backspace':    HidKey.usage(0x2A),
  'Tab':          HidKey.usage(0x2B),
  'Space':        HidKey.usage(0x2C),
  'Minus':        HidKey.usage(0x2D),
  'Equal':        HidKey.usage(0x2E),
  'BracketLeft':  HidKey.usage(0x2F),
  'BracketRight': HidKey.usage(0x30),
  'Backslash':    HidKey.usage(0x31),
  'Semicolon':    HidKey.usage(0x33),
  'Quote':        HidKey.usage(0x34),
  'Backquote':    HidKey.usage(0x35),
  'Comma':        HidKey.usage(0x36),
  'Period':       HidKey.usage(0x37),
  'Slash':        HidKey.usage(0x38),
  'CapsLock':     HidKey.usage(0x39),

  // F-keys
  'F1':  HidKey.usage(0x3A), 'F2':  HidKey.usage(0x3B),
  'F3':  HidKey.usage(0x3C), 'F4':  HidKey.usage(0x3D),
  'F5':  HidKey.usage(0x3E), 'F6':  HidKey.usage(0x3F),
  'F7':  HidKey.usage(0x40), 'F8':  HidKey.usage(0x41),
  'F9':  HidKey.usage(0x42), 'F10': HidKey.usage(0x43),
  'F11': HidKey.usage(0x44), 'F12': HidKey.usage(0x45),

  // Navigation
  'PrintScreen': HidKey.usage(0x46),
  'ScrollLock':  HidKey.usage(0x47),
  'Pause':       HidKey.usage(0x48),
  'Insert':      HidKey.usage(0x49),
  'Home':        HidKey.usage(0x4A),
  'PageUp':      HidKey.usage(0x4B),
  'Delete':      HidKey.usage(0x4C),
  'End':         HidKey.usage(0x4D),
  'PageDown':    HidKey.usage(0x4E),
  'ArrowRight':  HidKey.usage(0x4F),
  'ArrowLeft':   HidKey.usage(0x50),
  'ArrowDown':   HidKey.usage(0x51),
  'ArrowUp':     HidKey.usage(0x52),
};
