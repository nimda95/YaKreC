import 'package:flutter/material.dart';

import '../devices/base.dart';

/// Hijacks the system soft keyboard to drive HID. Renders an invisible
/// TextField that holds focus while the OS keyboard is up. We keep a
/// zero-width-space anchor in the controller; any deviation from it is
/// translated into key events and the controller is immediately reset.
///
/// Limitations: text only. Modifier combos (Ctrl+S etc.) aren't reachable
/// from a soft keyboard — use the custom OSK for those.
class SystemKeyboardCapture extends StatefulWidget {
  final DeviceClient client;
  final VoidCallback onClose;
  const SystemKeyboardCapture({
    super.key,
    required this.client,
    required this.onClose,
  });

  @override
  State<SystemKeyboardCapture> createState() => _SystemKeyboardCaptureState();
}

class _SystemKeyboardCaptureState extends State<SystemKeyboardCapture> {
  static const _anchor = '​';
  final _focus = FocusNode(debugLabel: 'native-kb');
  final _ctrl = TextEditingController(text: _anchor);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    _ctrl.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _ctrl.removeListener(_onChange);
    _focus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!mounted || _focus.hasFocus) return;
    // Reclaim focus so the OS soft keyboard stays up even when the user taps
    // somewhere else (display, options button, etc.). Dismiss only happens
    // explicitly via the menu's "Hide native keyboard" item, which unmounts
    // this widget. Matches aVNC's behaviour.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  Future<void> _onChange() async {
    final cur = _ctrl.text;
    if (cur == _anchor) return;
    if (cur.length > _anchor.length) {
      final added = cur.substring(_anchor.length);
      // Prefer the device's text-input path (PiKVM /api/hid/print) so
      // kvmd does the layout translation — what the user types on their
      // local IME (any layout, including AZERTY / Arabic) ends up
      // matching what the host renders. Falls back to per-char physical
      // keys when the device doesn't support it (NanoKVM today).
      var consumed = false;
      if (widget.client.supportsTextInput) {
        consumed = await widget.client.sendText(added);
      }
      if (!consumed) {
        for (final ch in added.split('')) {
          await _sendChar(ch);
        }
      }
    } else {
      final n = _anchor.length - cur.length;
      for (var i = 0; i < n; i++) {
        await widget.client.sendKey(code: 'Backspace', down: true);
        await widget.client.sendKey(code: 'Backspace', down: false);
      }
    }
    _ctrl.value = const TextEditingValue(
      text: _anchor,
      selection: TextSelection.collapsed(offset: _anchor.length),
    );
  }

  /// Per-character physical-key fallback. Used for devices that don't
  /// expose a layout-aware text endpoint. Assumes the local keyboard is
  /// US-QWERTY-shaped — characters outside that produce nothing here.
  Future<void> _sendChar(String ch) async {
    if (ch == '\n') {
      await widget.client.sendKey(code: 'Enter', down: true);
      await widget.client.sendKey(code: 'Enter', down: false);
      return;
    }
    final code = _charToCode(ch);
    if (code == null) return;
    final shift = _needsShift(ch);
    if (shift) await widget.client.sendKey(code: 'ShiftLeft', down: true);
    await widget.client.sendKey(code: code, down: true);
    await widget.client.sendKey(code: code, down: false);
    if (shift) await widget.client.sendKey(code: 'ShiftLeft', down: false);
  }

  static String? _charToCode(String c) {
    if (c.isEmpty) return null;
    final cu = c.codeUnitAt(0);
    if (cu >= 0x41 && cu <= 0x5A) return 'Key${c.toUpperCase()}';
    if (cu >= 0x61 && cu <= 0x7A) return 'Key${c.toUpperCase()}';
    if (cu >= 0x30 && cu <= 0x39) return 'Digit$c';
    return switch (c) {
      ' '  => 'Space',  '\t' => 'Tab',
      '.'  => 'Period', ','  => 'Comma',  '/'  => 'Slash',
      '-'  => 'Minus',  '='  => 'Equal',
      ';'  => 'Semicolon', "'" => 'Quote',
      '['  => 'BracketLeft',  ']' => 'BracketRight',
      '\\' => 'Backslash', '`' => 'Backquote',
      // Shift-+digit / shift-+symbol — same physical key, shift handled below.
      '!'  => 'Digit1', '@' => 'Digit2', '#' => 'Digit3', '\$' => 'Digit4',
      '%'  => 'Digit5', '^' => 'Digit6', '&' => 'Digit7', '*'  => 'Digit8',
      '('  => 'Digit9', ')' => 'Digit0',
      '_'  => 'Minus',  '+' => 'Equal',
      '{'  => 'BracketLeft', '}' => 'BracketRight', '|' => 'Backslash',
      ':'  => 'Semicolon', '"' => 'Quote',
      '<'  => 'Comma',  '>' => 'Period', '?' => 'Slash', '~' => 'Backquote',
      _    => null,
    };
  }

  static bool _needsShift(String c) {
    if (c.length != 1) return false;
    final cu = c.codeUnitAt(0);
    if (cu >= 0x41 && cu <= 0x5A) return true; // upper-case letters
    return r'!@#$%^&*()_+{}|:"<>?~'.contains(c);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      top: 0,
      width: 1,
      height: 1,
      child: Opacity(
        opacity: 0,
        child: TextField(
          focusNode: _focus,
          controller: _ctrl,
          autocorrect: false,
          enableSuggestions: false,
          // Multiline + newline action makes the IME render a real Enter
          // key instead of "Done" / "Go" / "Search" — matching what aVNC
          // gets by leaving EditorInfo's imeOptions free of any
          // IME_ACTION_*. The resulting "\n" round-trips through _onChange
          // → _sendChar where it's translated to a HID Enter press.
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          maxLines: null,
          decoration: const InputDecoration(
            border: InputBorder.none,
            isDense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}
