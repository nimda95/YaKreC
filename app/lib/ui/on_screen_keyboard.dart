import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../devices/base.dart';

/// Display layout for the on-screen keyboard. The DOM-style physical key
/// codes we send to the host don't change — only the labels do. The user
/// picks whichever layout matches the host's configured keyboard so the
/// labels they tap match the characters they get.
enum KeyboardLayout { qwerty, azerty }

/// Custom on-screen keyboard for the KVM display.
///
/// Behaviour the system soft keyboard can't give us:
///   * Each tap sends a real key-down/key-up to the device immediately.
///   * Modifier keys (Shift/Ctrl/Alt/Meta) are sticky toggles — tap once to
///     arm, tap again to release. They wrap the next key tap so combos work.
///   * Renders inline in a Stack overlay (no modal scrim), so the display
///     behind it stays interactive.
///   * Wrapped in [Focus] with `canRequestFocus: false` so the hardware
///     keyboard listener never loses focus when the user taps a key.
///
/// Two layouts:
///   * [floating] = false: docked at the bottom edge. No header.
///   * [floating] = true: a draggable panel with a header (drag handle,
///     collapse, close). Starts in the screen centre. Re-mount the widget
///     (change its [Key]) to re-centre after dragging.
class OnScreenKeyboard extends StatefulWidget {
  final DeviceClient client;
  final VoidCallback onHide;
  final bool floating;

  /// 0.30..1.00. Applied to the rendered keyboard so it can be made
  /// see-through when it covers part of the host video.
  final double opacity;

  final KeyboardLayout layout;

  /// Persisted floating-panel origin (top-left). Null on first mount —
  /// the widget falls back to its default centre placement and emits a
  /// value once the user drags.
  final Offset? initialPosition;
  final ValueChanged<Offset>? onPositionChanged;

  const OnScreenKeyboard({
    super.key,
    required this.client,
    required this.onHide,
    this.floating = false,
    this.opacity = 1.0,
    this.layout = KeyboardLayout.qwerty,
    this.initialPosition,
    this.onPositionChanged,
  });

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  /// Modifier codes currently locked sticky-on. Quick-tap toggles add to
  /// or remove from this set; mod-down/up are managed accordingly.
  final Set<String> _locked = {};

  /// Active modifier presses keyed by pointerId. One entry per finger
  /// currently on a modifier cap, so multi-touch holds don't collide.
  final Map<int, _ModPress> _modPresses = {};

  /// Active non-modifier presses keyed by pointerId. Non-modifier caps
  /// fire key-down on touch and key-up on lift, so a held finger keeps
  /// the host key pressed.
  final Map<int, String> _keyPresses = {};

  Offset? _pos;
  bool _collapsed = false;

  /// Default desired width for the floating panel. Actual width is clamped
  /// to fit the current screen so portrait phones don't overflow.
  static const _floatingWidthPreferred = 720.0;
  static const _floatingMargin = 16.0;
  static const _quickTapThreshold = Duration(milliseconds: 250);

  /// Marks every active modifier press as "another key was touched", so
  /// the upcoming pointerUp doesn't get treated as a quick-tap-to-lock.
  void _markCompanionTouch() {
    for (final p in _modPresses.values) {
      p.anotherKeyTouched = true;
    }
  }

  Future<void> _capPointerDown(int pointerId, _K k) async {
    if (k.isHide) return; // handled on pointerUp
    HapticFeedback.selectionClick();
    final code = k.code!;
    if (k.sticky) {
      _markCompanionTouch();
      final wasLocked = _locked.contains(code);
      _modPresses[pointerId] = _ModPress(code, DateTime.now(), wasLocked);
      if (!wasLocked) {
        await widget.client.sendKey(code: code, down: true);
      }
      setState(() {});
      return;
    }
    _markCompanionTouch();
    _keyPresses[pointerId] = code;
    await widget.client.sendKey(code: code, down: true);
  }

  Future<void> _capPointerUp(int pointerId, _K k) async {
    if (k.isHide) {
      widget.onHide();
      return;
    }
    final mod = _modPresses.remove(pointerId);
    if (mod != null) {
      final held = DateTime.now().difference(mod.startedAt);
      final wasQuickTap =
          held < _quickTapThreshold && !mod.anotherKeyTouched;
      if (mod.wasLockedAtTouch) {
        if (wasQuickTap) {
          _locked.remove(mod.code);
          await widget.client.sendKey(code: mod.code, down: false);
        }
      } else if (wasQuickTap) {
        _locked.add(mod.code);
      } else {
        await widget.client.sendKey(code: mod.code, down: false);
      }
      setState(() {});
      return;
    }
    final code = _keyPresses.remove(pointerId);
    if (code != null) {
      await widget.client.sendKey(code: code, down: false);
    }
  }

  Future<void> _capPointerCancel(int pointerId, _K k) =>
      _capPointerUp(pointerId, k);

  /// True if the given modifier code is currently active — either locked
  /// sticky-on or being held by a finger right now. Drives the cap
  /// highlight and the shifted-label rendering.
  bool _modActive(String code) =>
      _locked.contains(code) ||
      _modPresses.values.any((m) => m.code == code);

  @override
  Widget build(BuildContext context) {
    final keys = _buildKeys();
    if (!widget.floating) {
      return Opacity(
        opacity: widget.opacity,
        child: Focus(
          canRequestFocus: false,
          child: Material(
            color: const Color.fromARGB(230, 16, 16, 16),
            child: SafeArea(
              top: false,
              child: keys,
            ),
          ),
        ),
      );
    }
    final screen = MediaQuery.of(context).size;
    final width = _floatingWidthPreferred
        .clamp(0.0, screen.width - _floatingMargin)
        .toDouble();
    _pos ??= widget.initialPosition ??
        Offset(
          ((screen.width - width) / 2).clamp(0.0, screen.width).toDouble(),
          // Roughly centre vertically; collapsed/expanded heights differ but
          // recovering via menu re-centres anyway.
          ((screen.height / 2) - 120).clamp(0.0, screen.height).toDouble(),
        );
    // Positioned MUST be a direct child of Stack — caller wraps us in
    // Opacity at its peril. We apply opacity *inside* the Positioned tree.
    return Positioned(
      left: _pos!.dx,
      top: _pos!.dy,
      width: width,
      child: Opacity(
        opacity: widget.opacity,
        child: Focus(
          canRequestFocus: false,
          child: Material(
            color: const Color.fromARGB(230, 16, 16, 16),
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(screen, width),
                  if (!_collapsed) keys,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(Size screen, double width) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (d) {
        setState(() {
          // Clamp to the screen so the user can't drag the panel off-edge.
          final cur = _pos ?? Offset.zero;
          _pos = Offset(
            (cur.dx + d.delta.dx)
                .clamp(0.0, screen.width - width)
                .toDouble(),
            (cur.dy + d.delta.dy).clamp(0.0, screen.height - 80).toDouble(),
          );
        });
        widget.onPositionChanged?.call(_pos!);
      },
      child: Container(
        height: 28,
        color: const Color.fromARGB(255, 38, 38, 38),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            const Icon(Icons.drag_indicator,
                size: 16, color: Colors.white60),
            const SizedBox(width: 6),
            const Expanded(
              child: Text(
                'Keyboard',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
            InkWell(
              onTap: () => setState(() => _collapsed = !_collapsed),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  _collapsed ? Icons.expand_more : Icons.expand_less,
                  size: 18,
                  color: Colors.white70,
                ),
              ),
            ),
            InkWell(
              onTap: widget.onHide,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(Icons.close, size: 18, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeys() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(_numbersRow()),
          _row(_topAlphaRow()),
          _row(_homeAlphaRow()),
          _row(_bottomAlphaRow()),
          _row(_modifiersRow()),
        ],
      ),
    );
  }

  // ───── Layout-aware rows ─────────────────────────────────────────────────
  // Only the *labels* depend on layout; the DOM key codes are still the
  // physical ones, since the host's configured layout is what translates
  // physical → character. The user picks the layout whose labels match
  // their host so what they tap matches what gets typed.

  List<_K> _numbersRow() {
    if (widget.layout == KeyboardLayout.azerty) {
      return const [
        _K('Backquote', '²'),
        _K('Digit1', '&', shiftLabel: '1'),
        _K('Digit2', 'é', shiftLabel: '2', altGrLabel: '~'),
        _K('Digit3', '"', shiftLabel: '3', altGrLabel: '#'),
        _K('Digit4', "'", shiftLabel: '4', altGrLabel: '{'),
        _K('Digit5', '(', shiftLabel: '5', altGrLabel: '['),
        _K('Digit6', '-', shiftLabel: '6', altGrLabel: '|'),
        _K('Digit7', 'è', shiftLabel: '7', altGrLabel: '`'),
        _K('Digit8', '_', shiftLabel: '8', altGrLabel: r'\'),
        _K('Digit9', 'ç', shiftLabel: '9', altGrLabel: '^'),
        _K('Digit0', 'à', shiftLabel: '0', altGrLabel: '@'),
        _K('Minus', ')', shiftLabel: '°', altGrLabel: ']'),
        _K('Equal', '=', shiftLabel: '+', altGrLabel: '}'),
        _K('Backspace', '⌫', flex: 2),
      ];
    }
    return const [
      _K('Backquote', '`', shiftLabel: '~'),
      _K('Digit1', '1', shiftLabel: '!'),
      _K('Digit2', '2', shiftLabel: '@'),
      _K('Digit3', '3', shiftLabel: '#'),
      _K('Digit4', '4', shiftLabel: r'$'),
      _K('Digit5', '5', shiftLabel: '%'),
      _K('Digit6', '6', shiftLabel: '^'),
      _K('Digit7', '7', shiftLabel: '&'),
      _K('Digit8', '8', shiftLabel: '*'),
      _K('Digit9', '9', shiftLabel: '('),
      _K('Digit0', '0', shiftLabel: ')'),
      _K('Minus', '-', shiftLabel: '_'),
      _K('Equal', '=', shiftLabel: '+'),
      _K('Backspace', '⌫', flex: 2),
    ];
  }

  List<_K> _topAlphaRow() {
    if (widget.layout == KeyboardLayout.azerty) {
      return const [
        _K('Tab', 'Tab', flex: 2),
        _K('KeyQ', 'a'), _K('KeyW', 'z'), _K('KeyE', 'e', altGrLabel: '€'),
        _K('KeyR', 'r'), _K('KeyT', 't'), _K('KeyY', 'y'),
        _K('KeyU', 'u'), _K('KeyI', 'i'), _K('KeyO', 'o'),
        _K('KeyP', 'p'),
        _K('BracketLeft', '^', shiftLabel: '¨'),
        _K('BracketRight', '\$', shiftLabel: '£', altGrLabel: '¤'),
        _K('Backslash', '*', shiftLabel: 'µ'),
      ];
    }
    return const [
      _K('Tab', 'Tab', flex: 2),
      _K('KeyQ', 'q'), _K('KeyW', 'w'), _K('KeyE', 'e'),
      _K('KeyR', 'r'), _K('KeyT', 't'), _K('KeyY', 'y'),
      _K('KeyU', 'u'), _K('KeyI', 'i'), _K('KeyO', 'o'),
      _K('KeyP', 'p'),
      _K('BracketLeft', '[', shiftLabel: '{'),
      _K('BracketRight', ']', shiftLabel: '}'),
      _K('Backslash', r'\', shiftLabel: '|'),
    ];
  }

  List<_K> _homeAlphaRow() {
    if (widget.layout == KeyboardLayout.azerty) {
      return const [
        _K('Escape', 'Esc', flex: 2),
        _K('KeyA', 'q'), _K('KeyS', 's'), _K('KeyD', 'd'),
        _K('KeyF', 'f'), _K('KeyG', 'g'), _K('KeyH', 'h'),
        _K('KeyJ', 'j'), _K('KeyK', 'k'), _K('KeyL', 'l'),
        _K('Semicolon', 'm'),
        _K('Quote', 'ù', shiftLabel: '%'),
        _K('Enter', '⏎', flex: 3),
      ];
    }
    return const [
      _K('Escape', 'Esc', flex: 2),
      _K('KeyA', 'a'), _K('KeyS', 's'), _K('KeyD', 'd'),
      _K('KeyF', 'f'), _K('KeyG', 'g'), _K('KeyH', 'h'),
      _K('KeyJ', 'j'), _K('KeyK', 'k'), _K('KeyL', 'l'),
      _K('Semicolon', ';', shiftLabel: ':'),
      _K('Quote', "'", shiftLabel: '"'),
      _K('Enter', '⏎', flex: 3),
    ];
  }

  List<_K> _bottomAlphaRow() {
    if (widget.layout == KeyboardLayout.azerty) {
      return const [
        _K('ShiftLeft', '⇧', sticky: true, flex: 2),
        _K('KeyZ', 'w'), _K('KeyX', 'x'), _K('KeyC', 'c'),
        _K('KeyV', 'v'), _K('KeyB', 'b'), _K('KeyN', 'n'),
        _K('KeyM', ',', shiftLabel: '?'),
        _K('Comma', ';', shiftLabel: '.'),
        _K('Period', ':', shiftLabel: '/'),
        _K('Slash', '!', shiftLabel: '§'),
        _K('ShiftRight', '⇧', sticky: true, flex: 2),
      ];
    }
    return const [
      _K('ShiftLeft', '⇧', sticky: true, flex: 2),
      _K('KeyZ', 'z'), _K('KeyX', 'x'), _K('KeyC', 'c'),
      _K('KeyV', 'v'), _K('KeyB', 'b'), _K('KeyN', 'n'),
      _K('KeyM', 'm'),
      _K('Comma', ',', shiftLabel: '<'),
      _K('Period', '.', shiftLabel: '>'),
      _K('Slash', '/', shiftLabel: '?'),
      _K('ShiftRight', '⇧', sticky: true, flex: 2),
    ];
  }

  List<_K> _modifiersRow() {
    if (widget.layout == KeyboardLayout.azerty) {
      // AZERTY users need AltGr (right-Alt) to type @ # { [ | ` etc. The
      // base label switches when AltGr is armed, so include the toggle in
      // the row.
      return const [
        _K('ControlLeft', 'Ctrl', sticky: true, flex: 2),
        _K('AltLeft', 'Alt', sticky: true, flex: 2),
        _K('AltRight', 'AltGr', sticky: true, flex: 2),
        _K('Space', '␣', flex: 6),
        _K('ArrowLeft', '←'),
        _K('ArrowDown', '↓'),
        _K('ArrowUp', '↑'),
        _K('ArrowRight', '→'),
        _K.hide(flex: 2),
      ];
    }
    return const [
      _K('ControlLeft', 'Ctrl', sticky: true, flex: 2),
      _K('AltLeft', 'Alt', sticky: true, flex: 2),
      _K('MetaLeft', '⌘', sticky: true, flex: 2),
      _K('Space', '␣', flex: 6),
      _K('ArrowLeft', '←'),
      _K('ArrowDown', '↓'),
      _K('ArrowUp', '↑'),
      _K('ArrowRight', '→'),
      _K.hide(flex: 2),
    ];
  }

  Widget _row(List<_K> keys) {
    final shift = _modActive('ShiftLeft') || _modActive('ShiftRight');
    final altGr = _modActive('AltRight');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: keys
            .map((k) => Expanded(
                  flex: k.flex,
                  child: _Cap(
                    label: k.resolvedLabel(shift: shift, altGr: altGr),
                    active: k.sticky &&
                        k.code != null &&
                        _modActive(k.code!),
                    onPointerDown: (id) => _capPointerDown(id, k),
                    onPointerUp: (id) => _capPointerUp(id, k),
                    onPointerCancel: (id) => _capPointerCancel(id, k),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

/// Per-pointer record of a modifier press in flight on the OSK.
class _ModPress {
  final String code;
  final DateTime startedAt;
  bool wasLockedAtTouch;
  bool anotherKeyTouched;
  _ModPress(this.code, this.startedAt, this.wasLockedAtTouch)
      : anotherKeyTouched = false;
}

class _K {
  final String? code;
  final String label;

  /// Label to render when Shift is currently armed. Letters auto-uppercase
  /// when [shiftLabel] is null (so we don't have to spell out 26 entries).
  /// Punctuation/digits set this explicitly because the shifted form isn't
  /// case-derivable.
  final String? shiftLabel;

  /// Label to render when AltGr (right-Alt) is currently armed. Used for
  /// AZERTY's `é → @`, `" → #`, etc. Null = no alt form, fall back to
  /// [label] / [shiftLabel].
  final String? altGrLabel;

  final bool sticky;
  final bool isHide;
  final int flex;
  const _K(
    this.code,
    this.label, {
    this.shiftLabel,
    this.altGrLabel,
    this.sticky = false,
    this.flex = 1,
  }) : isHide = false;
  const _K.hide({this.flex = 1})
      : code = null,
        label = '⌄',
        shiftLabel = null,
        altGrLabel = null,
        sticky = false,
        isHide = true;

  /// Resolve the label that should currently render given the active
  /// modifier set. Precedence: AltGr > Shift > base; letters fall through
  /// to a `.toUpperCase()` when shift is on and no explicit shifted form
  /// is provided.
  String resolvedLabel({
    required bool shift,
    required bool altGr,
  }) {
    if (altGr && altGrLabel != null) return altGrLabel!;
    if (shift) {
      if (shiftLabel != null) return shiftLabel!;
      // Single lowercase letter → upper. Anything else: leave as-is.
      if (label.length == 1 && label.toLowerCase() == label) {
        return label.toUpperCase();
      }
    }
    return label;
  }
}

class _Cap extends StatelessWidget {
  final String label;
  final bool active;
  final void Function(int pointerId) onPointerDown;
  final void Function(int pointerId) onPointerUp;
  final void Function(int pointerId) onPointerCancel;
  const _Cap({
    required this.label,
    required this.active,
    required this.onPointerDown,
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(2),
      // Listener (not GestureDetector.onTap) so each finger gets its own
      // pointer events. Multi-touch then routes through the parent state's
      // pointer maps and Ctrl + Alt + Del with three fingers Just Works.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => onPointerDown(e.pointer),
        onPointerUp: (e) => onPointerUp(e.pointer),
        onPointerCancel: (e) => onPointerCancel(e.pointer),
        child: Container(
          decoration: BoxDecoration(
            color: active
                ? const Color.fromARGB(255, 220, 165, 32)
                : const Color.fromARGB(255, 50, 50, 50),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: const Color.fromARGB(255, 80, 80, 80),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                color: active ? Colors.black : Colors.white,
                fontSize: 14,
                fontWeight:
                    active ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
