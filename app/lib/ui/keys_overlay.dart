import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../devices/base.dart';

/// A horizontally-scrollable, draggable bar of "common" KVM keys overlaid on
/// the host video: F1–F12, modifiers (Ctrl/Alt/AltGr/Shift), Caps Lock
/// (state-synced with the device when [DeviceClient.keyboardLeds] is
/// available), Esc/Del, and arrow keys.
///
/// Press model:
///   * Each cap fires `key-down` on `pointerDown` and `key-up` on
///     `pointerUp`. Multi-touch is supported by Flutter's pointer router,
///     so the user can hold Ctrl + Alt with two fingers and tap Del with a
///     third — that produces a real Ctrl+Alt+Del at the host.
///   * For one-handed use, a *quick tap* (≤ 250 ms, no other cap touched
///     in between) on a modifier *locks* it sticky-on. The mod-down stays
///     sent. A subsequent quick tap on the locked cap unlocks (mod-up).
///   * Caps Lock stays as a one-shot: tap fires CapsLock down/up; the
///     visual state mirrors the host's LED via `keyboardLeds`.
class KeysOverlay extends StatefulWidget {
  final DeviceClient client;
  final double opacity;
  final VoidCallback onHide;

  /// Persisted vertical position (top, in screen coords). Null = use the
  /// default safe-area-top placement. Position is full-width so we never
  /// persist X.
  final double? initialY;
  final ValueChanged<double>? onPositionChanged;

  const KeysOverlay({
    super.key,
    required this.client,
    required this.onHide,
    this.opacity = 0.85,
    this.initialY,
    this.onPositionChanged,
  });

  @override
  State<KeysOverlay> createState() => _KeysOverlayState();
}

/// Per-pointer record of a modifier press in flight.
class _ModPress {
  final String code;
  final DateTime startedAt;
  bool wasLockedAtTouch;
  bool anotherKeyTouched;
  _ModPress(this.code, this.startedAt, this.wasLockedAtTouch)
      : anotherKeyTouched = false;
}

class _KeysOverlayState extends State<KeysOverlay> {
  /// Modifier codes currently locked sticky-on. Highlighted; blocks the
  /// auto-mod-up on pointerUp.
  final Set<String> _locked = {};

  /// Active modifier presses keyed by pointerId. Each one represents a
  /// finger currently on a modifier cap. We track these per pointer so
  /// multi-touch presses don't collide.
  final Map<int, _ModPress> _modPresses = {};

  /// Active non-modifier presses keyed by pointerId. Used to send the
  /// matching key-up on pointerUp / pointerCancel.
  final Map<int, String> _keyPresses = {};

  Offset? _pos;

  static const _barHeight = 48.0;
  static const _quickTapThreshold = Duration(milliseconds: 250);

  static const _modCodes = {
    'ControlLeft', 'AltLeft', 'AltRight', 'ShiftLeft',
  };

  // ───── Pointer dispatch ──────────────────────────────────────────────────

  /// Marks every active modifier press as "another key was touched", so
  /// the upcoming pointerUp doesn't get treated as a quick-tap-to-lock.
  void _markCompanionTouch() {
    for (final p in _modPresses.values) {
      p.anotherKeyTouched = true;
    }
  }

  Future<void> _capPointerDown(int pointerId, String code) async {
    HapticFeedback.selectionClick();
    if (_modCodes.contains(code)) {
      // Companion touches must observe the *prior* set of held mods,
      // before this one joins.
      _markCompanionTouch();
      final wasLocked = _locked.contains(code);
      _modPresses[pointerId] = _ModPress(code, DateTime.now(), wasLocked);
      if (!wasLocked) {
        await widget.client.sendKey(code: code, down: true);
      }
      setState(() {});
      return;
    }
    // Non-modifier key.
    _markCompanionTouch();
    _keyPresses[pointerId] = code;
    await widget.client.sendKey(code: code, down: true);
  }

  Future<void> _capPointerUp(int pointerId) async {
    final mod = _modPresses.remove(pointerId);
    if (mod != null) {
      final held = DateTime.now().difference(mod.startedAt);
      final wasQuickTap =
          held < _quickTapThreshold && !mod.anotherKeyTouched;
      if (mod.wasLockedAtTouch) {
        // The cap was locked before this touch began.
        // Quick tap on a locked mod = release lock.
        if (wasQuickTap) {
          _locked.remove(mod.code);
          await widget.client.sendKey(code: mod.code, down: false);
        }
        // Otherwise the user was using the locked cap as a hold target
        // for some multi-touch sequence; keep the lock and the mod-down.
      } else if (wasQuickTap) {
        // Fresh quick tap with no companion key → lock sticky-on. The
        // mod-down was already sent on touch; intentionally skip the up.
        _locked.add(mod.code);
      } else {
        // Real hold (or the user touched another cap while held). Release.
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

  Future<void> _capPointerCancel(int pointerId) async {
    // Identical effect to up: make sure we don't leave stuck keys.
    await _capPointerUp(pointerId);
  }

  Future<void> _tapCaps() async {
    HapticFeedback.selectionClick();
    // CapsLock stays a one-shot — we never want to "hold" it because the
    // host's LED toggles on each press. The KeysOverlay's Caps cap calls
    // this on tap (not on hold).
    await widget.client.sendKey(code: 'CapsLock', down: true);
    await widget.client.sendKey(code: 'CapsLock', down: false);
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    _pos ??= Offset(
      0,
      widget.initialY ?? (padding.top + 8),
    );
    return Positioned(
      left: _pos!.dx,
      top: _pos!.dy,
      width: screen.width,
      child: Opacity(
        opacity: widget.opacity,
        child: SizedBox(
          height: _barHeight,
          child: Material(
            color: const Color.fromARGB(230, 16, 16, 16),
            elevation: 6,
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                _DragHandle(
                  onDrag: (delta) {
                    setState(() {
                      _pos = Offset(
                        _pos!.dx,
                        (_pos!.dy + delta.dy)
                            .clamp(0.0, screen.height - _barHeight)
                            .toDouble(),
                      );
                    });
                    widget.onPositionChanged?.call(_pos!.dy);
                  },
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: _buildKeys(context),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  color: Colors.white70,
                  onPressed: widget.onHide,
                  tooltip: 'Hide keys overlay',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildKeys(BuildContext ctx) {
    final out = <Widget>[
      _Cap(
        label: 'Esc',
        active: false,
        onPointerDown: (id) => _capPointerDown(id, 'Escape'),
        onPointerUp: _capPointerUp,
        onPointerCancel: _capPointerCancel,
      ),
      const _Sep(),
    ];
    for (var i = 1; i <= 12; i++) {
      out.add(_Cap(
        label: 'F$i',
        active: false,
        onPointerDown: (id) => _capPointerDown(id, 'F$i'),
        onPointerUp: _capPointerUp,
        onPointerCancel: _capPointerCancel,
      ));
    }
    out.addAll([
      const _Sep(),
      _modCap('Ctrl', 'ControlLeft'),
      _modCap('Alt', 'AltLeft'),
      _modCap('AltGr', 'AltRight'),
      _modCap('Shift', 'ShiftLeft'),
      _capsLockBuilder(),
      const _Sep(),
      _Cap(
        label: 'Del',
        active: false,
        onPointerDown: (id) => _capPointerDown(id, 'Delete'),
        onPointerUp: _capPointerUp,
        onPointerCancel: _capPointerCancel,
      ),
      const _Sep(),
      _Cap(
        label: '←',
        active: false,
        onPointerDown: (id) => _capPointerDown(id, 'ArrowLeft'),
        onPointerUp: _capPointerUp,
        onPointerCancel: _capPointerCancel,
      ),
      _Cap(
        label: '↓',
        active: false,
        onPointerDown: (id) => _capPointerDown(id, 'ArrowDown'),
        onPointerUp: _capPointerUp,
        onPointerCancel: _capPointerCancel,
      ),
      _Cap(
        label: '↑',
        active: false,
        onPointerDown: (id) => _capPointerDown(id, 'ArrowUp'),
        onPointerUp: _capPointerUp,
        onPointerCancel: _capPointerCancel,
      ),
      _Cap(
        label: '→',
        active: false,
        onPointerDown: (id) => _capPointerDown(id, 'ArrowRight'),
        onPointerUp: _capPointerUp,
        onPointerCancel: _capPointerCancel,
      ),
      const SizedBox(width: 8),
    ]);
    return out;
  }

  Widget _modCap(String label, String code) {
    // "active" reflects either: a finger currently held on the cap, OR
    // the modifier being locked sticky-on. Both produce the highlight.
    final activeByHold = _modPresses.values.any((m) => m.code == code);
    final activeByLock = _locked.contains(code);
    return _Cap(
      label: label,
      active: activeByHold || activeByLock,
      isModifier: true,
      onPointerDown: (id) => _capPointerDown(id, code),
      onPointerUp: _capPointerUp,
      onPointerCancel: _capPointerCancel,
    );
  }

  Widget _capsLockBuilder() {
    final notifier = widget.client.keyboardLeds;
    Widget wrap(bool active) => _Cap(
          label: 'Caps',
          active: active,
          isModifier: true,
          // CapsLock toggles on each host event — we don't track it as a
          // press-and-hold, so the cap just fires a tap on pointerUp.
          onPointerDown: (_) {},
          onPointerUp: (_) => _tapCaps(),
          onPointerCancel: (_) {},
        );
    if (notifier == null) return wrap(false);
    return ValueListenableBuilder<KeyboardLeds>(
      valueListenable: notifier,
      builder: (_, leds, __) => wrap(leds.capsLock),
    );
  }
}

/// One key cap. Replaces the previous InkWell-based widget with a Listener
/// so we can route pointer events one-by-one; multi-touch goes through a
/// shared per-pointer state in the parent.
class _Cap extends StatelessWidget {
  final String label;
  final bool active;
  final bool isModifier;
  final void Function(int pointerId) onPointerDown;
  final void Function(int pointerId) onPointerUp;
  final void Function(int pointerId) onPointerCancel;
  const _Cap({
    required this.label,
    required this.active,
    required this.onPointerDown,
    required this.onPointerUp,
    required this.onPointerCancel,
    this.isModifier = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final minW = isModifier ? 48.0 : 40.0;
    return Listener(
      // Opaque so finger-down doesn't fall through to a sibling cap when
      // the user does a sloppy multi-touch.
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => onPointerDown(e.pointer),
      onPointerUp: (e) => onPointerUp(e.pointer),
      onPointerCancel: (e) => onPointerCancel(e.pointer),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        constraints: BoxConstraints(minWidth: minW, minHeight: 36),
        decoration: BoxDecoration(
          color: active
              ? scheme.primary
              : const Color.fromARGB(255, 36, 36, 36),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: active ? scheme.onPrimary : Colors.white,
            fontSize: 14,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();
  @override
  Widget build(BuildContext context) => const SizedBox(width: 6);
}

class _DragHandle extends StatelessWidget {
  final void Function(Offset delta) onDrag;
  const _DragHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanUpdate: (d) => onDrag(d.delta),
      child: Container(
        width: 28,
        alignment: Alignment.center,
        child: const Icon(
          Icons.drag_indicator,
          size: 18,
          color: Colors.white54,
        ),
      ),
    );
  }
}
