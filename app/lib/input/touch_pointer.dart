import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../devices/base.dart';

/// Routes pointer input over the display to KVM mouse events.
///
/// Touch (Android, touchscreens) — *trackpad* mode (absolute pointer OFF):
///   * 1-finger drag        → relative cursor movement (no button)
///   * 1-finger tap         → left click at current cursor
///   * Double-tap-and-drag  → left button **held** during drag
///   * 1-finger long-press  → right click at current cursor (no move)
///   * 2-finger tap         → right click at current cursor (no move)
///   * 3-finger tap         → middle click at current cursor (no move)
///   * 2-finger drag (zoom locked)   → wheel scroll (h + v)
///   * 2-finger pinch (zoom unlocked)→ InteractiveViewer pinch zoom
///
/// Touch (Android, touchscreens) — *touchscreen* mode (absolute pointer ON):
///   * 1-finger tap         → cursor jumps to the tap point, then left click
///   * 1-finger drag        → cursor jumps to start, left button held while
///                            the cursor follows the finger, released on lift
///   * 1-finger long-press  → right click at current cursor (no move)
///   * 2-finger tap         → right click at current cursor (no move)
///   * 3-finger tap         → middle click at current cursor (no move)
///   * 2-finger drag (zoom locked)   → wheel scroll (h + v)
///   * 2-finger pinch (zoom unlocked)→ InteractiveViewer pinch zoom
///
/// Mouse (Linux desktop, USB mice on Android):
///   * left / right / middle button down + up — bitfield diff'd per event
///   * Movement (drag *and* hover) → relative cursor movement
///   * Wheel scroll → mouse wheel (h + v)
///
/// Implemented with [Listener] (raw pointer events) so it doesn't compete
/// with [InteractiveViewer]'s gesture arena. We just inspect how many
/// fingers are down and ignore multi-pointer movement when the user is
/// pinching.
class TouchPointer extends StatefulWidget {
  final DeviceClient client;
  final Widget child;
  final bool zoomLocked;
  final bool enabled;

  /// When true, stylus and mouse hover/move events emit absolute mouse
  /// reports mapped to the host video. Touch fingers always stay on the
  /// relative trackpad UX regardless. No-op if [hostVideoSize] is null.
  final bool useAbsolute;

  /// Live host video resolution. Kept for diagnostic logging only — actual
  /// pointer mapping uses the explicit [videoRect] below.
  final Size? Function() hostVideoSize;

  /// Returns the rendered video rect (offset + size) in the TouchPointer's
  /// own local coordinate system. The caller mounts a `SizedBox` keyed
  /// with a [GlobalKey] that is *exactly* the BoxFit.contain rect of the
  /// host video, then provides this callback so we can read it live.
  /// Null = video box hasn't mounted yet.
  final Rect? Function() videoRect;

  /// Transform applied by the [InteractiveViewer] above us. We invert it
  /// so absolute coords are computed in the unscaled child space.
  final TransformationController? viewerTransform;

  /// Multiplier applied to relative pointer deltas (touchpad / hover / mouse
  /// movement). 1.0 = identity. Persisted per device profile.
  final double mouseSensitivity;

  /// Multiplier applied to wheel deltas (touch 2-finger scroll, mouse wheel).
  final double scrollSensitivity;

  const TouchPointer({
    super.key,
    required this.client,
    required this.child,
    required this.zoomLocked,
    this.useAbsolute = false,
    required this.hostVideoSize,
    required this.videoRect,
    this.viewerTransform,
    this.enabled = true,
    this.mouseSensitivity = 1.0,
    this.scrollSensitivity = 1.0,
  });

  @override
  State<TouchPointer> createState() => _TouchPointerState();
}

class _Pointer {
  final Offset start;
  Offset current;
  _Pointer(this.start) : current = start;
}

class _TouchPointerState extends State<TouchPointer> {
  // Touch state
  final Map<int, _Pointer> _touch = {};
  int _peakTouchCount = 0;
  bool _gestureMoved = false;
  Offset? _lastSingle;
  Offset? _lastCentroid;

  // Mouse state — bitmask of currently pressed mouse buttons.
  int _mouseButtons = 0;

  // Double-tap-and-drag state.
  DateTime? _lastTapTime;
  bool _dragCandidate = false;
  bool _holdingLeft = false;

  // Long-press state (right-click without moving cursor).
  Timer? _longPressTimer;
  bool _consumedByLongPress = false;

  // Throttled diagnostic logging for absolute pointer alignment debugging.
  DateTime _lastDiag = DateTime.fromMillisecondsSinceEpoch(0);

  static const _tapSlop = 10.0;
  static const _doubleTapWindow = Duration(milliseconds: 300);
  static const _longPressDur = Duration(milliseconds: 500);

  // ───── Pointer dispatch ──────────────────────────────────────────────────

  void _onDown(PointerDownEvent e) {
    if (!widget.enabled) return;
    if (e.kind == PointerDeviceKind.mouse ||
        e.kind == PointerDeviceKind.stylus) {
      _mouseDown(e);
    } else {
      _touchDown(e);
    }
  }

  void _onMove(PointerMoveEvent e) {
    if (!widget.enabled) return;
    if (e.kind == PointerDeviceKind.mouse ||
        e.kind == PointerDeviceKind.stylus) {
      _mouseMove(e);
    } else {
      _touchMove(e);
    }
  }

  void _onUp(PointerUpEvent e) {
    if (!widget.enabled) {
      _touch.remove(e.pointer);
      return;
    }
    if (e.kind == PointerDeviceKind.mouse ||
        e.kind == PointerDeviceKind.stylus) {
      _mouseUp(e);
    } else {
      _touchUp(e);
    }
  }

  void _onCancel(PointerCancelEvent e) {
    _touch.remove(e.pointer);
    if (_touch.isEmpty) {
      _cancelLongPress();
      if (_holdingLeft) {
        widget.client.sendMouseButton(MouseButton.left, false);
        _holdingLeft = false;
      }
      _resetTouch();
    }
  }

  /// Mouse / stylus hover (tip not touching, or mouse moving without
  /// buttons). On desktop a real mouse hovers constantly; with an S-Pen the
  /// hover phase is the natural way to drive the cursor before tapping.
  void _onHover(PointerHoverEvent e) {
    if (!widget.enabled) return;
    if (e.kind != PointerDeviceKind.mouse &&
        e.kind != PointerDeviceKind.stylus) {
      return;
    }
    // The S-Pen reports its side button via `event.buttons` even when the
    // tip isn't touching the screen. Diff buttons here so a side-button
    // press during hover registers as a right click.
    if (e.buttons != _mouseButtons) {
      _diffButtons(_mouseButtons, e.buttons);
      _mouseButtons = e.buttons;
    }
    if (_sendAbsolute(e.localPosition)) return;
    if (e.delta.dx == 0 && e.delta.dy == 0) return;
    widget.client.sendMouseRel(
      e.delta.dx * widget.mouseSensitivity,
      e.delta.dy * widget.mouseSensitivity,
    );
  }

  /// Sends an absolute mouse event when the pointer is over the video area.
  /// Returns true while [useAbsolute] is active so callers always suppress
  /// the relative-delta fallback — sending relative on top of the absolute
  /// pipeline causes the cursor to drift ahead of the pen at the edges.
  bool _sendAbsolute(Offset local) {
    if (!widget.useAbsolute) return false;
    final n = _toNormalized(local);
    if (n != null) {
      widget.client.sendMouseAbs(n.dx, n.dy);
    }
    return true;
  }

  /// Maps a pointer's local position to (0..1, 0..1) over the host video.
  ///
  /// We don't infer the video rect from BoxFit math anymore — that depended
  /// on the content widget (RTCVideoView / Image.memory) actually filling
  /// its parent under loose constraints, which is not guaranteed. Instead
  /// the connect page mounts a SizedBox sized to *exactly* the rendered
  /// video rect and lets us read its live position via [videoRect]. The
  /// math here just becomes "where in that rect did the user touch?".
  ///
  /// Pointer events arrive in TouchPointer-local coords. The InteractiveViewer
  /// scaleEnabled flag is disabled in absolute mode upstream, so the
  /// controller stays at identity. We still apply the inverse transform
  /// defensively in case a residual transform survives a mode switch.
  Offset? _toNormalized(Offset local) {
    final rect = widget.videoRect();
    if (rect == null) return null;
    if (rect.width <= 0 || rect.height <= 0) return null;

    var p = local;
    final t = widget.viewerTransform?.value;
    if (t != null) {
      try {
        final inv = Matrix4.inverted(t);
        p = MatrixUtils.transformPoint(inv, local);
      } catch (_) {
        return null;
      }
    }

    // Clamp to [0, 1] instead of rejecting out-of-bounds points: when the
    // pen drifts into the letterbox bars we want the cursor pinned to the
    // nearest video edge, not floating off via the relative-delta fallback.
    final nx = ((p.dx - rect.left) / rect.width).clamp(0.0, 1.0);
    final ny = ((p.dy - rect.top) / rect.height).clamp(0.0, 1.0);

    final now = DateTime.now();
    if (now.difference(_lastDiag).inMilliseconds >= 500) {
      _lastDiag = now;
      final s = (widget.viewerTransform?.value.entry(0, 0) ?? 1.0)
          .toStringAsFixed(2);
      final video = widget.hostVideoSize();
      widget.client.logger.d(
        'touch.abs',
        'local=(${local.dx.toStringAsFixed(0)},${local.dy.toStringAsFixed(0)}) '
        'scale=$s '
        'child=(${p.dx.toStringAsFixed(0)},${p.dy.toStringAsFixed(0)}) '
        'rect=(${rect.left.toStringAsFixed(0)},${rect.top.toStringAsFixed(0)} '
        '${rect.width.toStringAsFixed(0)}x${rect.height.toStringAsFixed(0)}) '
        'vsz=(${video?.width.toStringAsFixed(0)}x${video?.height.toStringAsFixed(0)}) '
        'n=(${nx.toStringAsFixed(3)},${ny.toStringAsFixed(3)})',
      );
    }

    return Offset(nx, ny);
  }

  void _onSignal(PointerSignalEvent e) {
    if (!widget.enabled) return;
    if (e is PointerScrollEvent) {
      widget.client.sendMouseWheel(
        e.scrollDelta.dx * widget.scrollSensitivity,
        e.scrollDelta.dy * widget.scrollSensitivity,
      );
    }
  }

  // ───── Mouse path ────────────────────────────────────────────────────────

  void _mouseDown(PointerDownEvent e) {
    // Position the cursor before the click in absolute mode, otherwise the
    // button event lands wherever the host cursor happened to be.
    _sendAbsolute(e.localPosition);
    _diffButtons(_mouseButtons, e.buttons);
    _mouseButtons = e.buttons;
  }

  void _mouseMove(PointerMoveEvent e) {
    if (!_sendAbsolute(e.localPosition)) {
      if (e.delta.dx != 0 || e.delta.dy != 0) {
        widget.client.sendMouseRel(
          e.delta.dx * widget.mouseSensitivity,
          e.delta.dy * widget.mouseSensitivity,
        );
      }
    }
    if (e.buttons != _mouseButtons) {
      _diffButtons(_mouseButtons, e.buttons);
      _mouseButtons = e.buttons;
    }
  }

  void _mouseUp(PointerUpEvent e) {
    _sendAbsolute(e.localPosition);
    _diffButtons(_mouseButtons, e.buttons);
    _mouseButtons = e.buttons;
  }

  void _diffButtons(int oldB, int newB) {
    void check(int mask, MouseButton btn) {
      final was = (oldB & mask) != 0;
      final now = (newB & mask) != 0;
      if (was != now) widget.client.sendMouseButton(btn, now);
    }
    check(kPrimaryButton, MouseButton.left);
    check(kSecondaryButton, MouseButton.right);
    check(kMiddleMouseButton, MouseButton.middle);
  }

  // ───── Touch path ────────────────────────────────────────────────────────

  void _scheduleLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(_longPressDur, () {
      if (_touch.length != 1 || _gestureMoved || _consumedByLongPress) return;
      HapticFeedback.mediumImpact();
      _consumedByLongPress = true;
      // Right click at the current host cursor — never move the cursor to
      // the touch point. Same wire shape in both touch modes.
      _click(MouseButton.right);
    });
  }

  void _cancelLongPress() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _touchDown(PointerDownEvent e) {
    _touch[e.pointer] = _Pointer(e.localPosition);
    if (_touch.length > _peakTouchCount) _peakTouchCount = _touch.length;
    if (_touch.length == 1) {
      _gestureMoved = false;
      _consumedByLongPress = false;
      _lastSingle = e.localPosition;
      _lastCentroid = null;
      // Right-click via long-press — same in both modes.
      _scheduleLongPress();
      // Trackpad mode only: detect double-tap-and-drag.
      if (!widget.useAbsolute &&
          _lastTapTime != null &&
          DateTime.now().difference(_lastTapTime!) < _doubleTapWindow) {
        _dragCandidate = true;
      }
    } else {
      // Multi-finger: cancel single-finger states.
      _lastSingle = null;
      _lastCentroid = _centroid();
      _dragCandidate = false;
      _cancelLongPress();
      if (_holdingLeft) {
        widget.client.sendMouseButton(MouseButton.left, false);
        _holdingLeft = false;
      }
    }
  }

  void _touchMove(PointerMoveEvent e) {
    final p = _touch[e.pointer];
    if (p == null) return;
    p.current = e.localPosition;
    if (!_gestureMoved && (p.current - p.start).distance > _tapSlop) {
      _gestureMoved = true;
      _cancelLongPress();
    }

    if (_touch.length == 1) {
      if (!_gestureMoved) return;
      if (widget.useAbsolute) {
        // Touchscreen drag: cursor jumps to where the finger is, left
        // button stays down while the finger moves, released on lift.
        if (!_holdingLeft) {
          _sendAbsolute(p.current);
          widget.client.sendMouseButton(MouseButton.left, true);
          _holdingLeft = true;
        }
        _sendAbsolute(p.current);
      } else {
        // Trackpad relative drag (existing).
        if (_dragCandidate && !_holdingLeft) {
          _holdingLeft = true;
          _dragCandidate = false;
          _lastTapTime = null;
          widget.client.sendMouseButton(MouseButton.left, true);
        }
        final last = _lastSingle ?? p.start;
        _lastSingle = p.current;
        widget.client.sendMouseRel(
          (p.current.dx - last.dx) * widget.mouseSensitivity,
          (p.current.dy - last.dy) * widget.mouseSensitivity,
        );
      }
    } else if (_touch.length == 2) {
      if (!widget.zoomLocked) return;
      if (!_gestureMoved) return;
      final c = _centroid();
      if (_lastCentroid != null) {
        final dx = c.dx - _lastCentroid!.dx;
        final dy = c.dy - _lastCentroid!.dy;
        widget.client.sendMouseWheel(
          -dx * widget.scrollSensitivity,
          -dy * widget.scrollSensitivity,
        );
      }
      _lastCentroid = c;
    }
  }

  void _touchUp(PointerUpEvent e) {
    _touch.remove(e.pointer);
    if (_touch.isNotEmpty) {
      _lastCentroid = _centroid();
      return;
    }
    _cancelLongPress();

    if (_holdingLeft) {
      widget.client.sendMouseButton(MouseButton.left, false);
      _holdingLeft = false;
      _lastTapTime = null;
    } else if (!_gestureMoved && !_consumedByLongPress) {
      switch (_peakTouchCount) {
        case 1:
          // In touchscreen (absolute) mode: cursor jumps to the tap point
          // first, then left click. In trackpad mode: just click at the
          // current host cursor (no move).
          if (widget.useAbsolute && _lastSingle != null) {
            _sendAbsolute(_lastSingle!);
          }
          _click(MouseButton.left);
          _lastTapTime = DateTime.now();
          break;
        case 2:
          // Right click WITHOUT moving cursor — both modes.
          _click(MouseButton.right);
          _lastTapTime = null;
          break;
        case 3:
          // Middle click WITHOUT moving cursor — both modes.
          _click(MouseButton.middle);
          _lastTapTime = null;
          break;
        default:
          break;
      }
    } else {
      _lastTapTime = null;
    }
    _resetTouch();
  }

  Offset _centroid() {
    if (_touch.isEmpty) return Offset.zero;
    var x = 0.0, y = 0.0;
    for (final p in _touch.values) {
      x += p.current.dx;
      y += p.current.dy;
    }
    return Offset(x / _touch.length, y / _touch.length);
  }

  Future<void> _click(MouseButton b) async {
    await widget.client.sendMouseButton(b, true);
    await widget.client.sendMouseButton(b, false);
  }

  void _resetTouch() {
    _peakTouchCount = 0;
    _gestureMoved = false;
    _consumedByLongPress = false;
    _lastSingle = null;
    _lastCentroid = null;
    _dragCandidate = false;
    _cancelLongPress();
    // _lastTapTime intentionally persists so the next gesture can detect
    // double-tap-and-drag in trackpad mode.
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      onPointerHover: _onHover,
      onPointerSignal: _onSignal,
      child: widget.child,
    );
  }
}
