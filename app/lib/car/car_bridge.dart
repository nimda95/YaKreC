import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Talks to the Kotlin [KvmFrameBridge] over a single [MethodChannel].
///
/// Flutter → native:
///   * `pushFrame` — send a JPEG to be drawn on the AA Surface.
///   * `clearFrame` — remove the current frame, e.g. on disconnect.
///
/// Native → Flutter (callbacks the consumer wires up):
///   * [onClick]  — user tapped on the AA Surface; coords normalised 0..1.
///   * [onScroll] — user dragged on the AA Surface; raw pixel deltas.
///   * [onReload] — user tapped the "Reload" action.
///
/// All methods are no-ops on non-Android platforms so callers don't have to
/// guard. They also swallow PlatformExceptions silently — the bridge is a
/// best-effort side channel; if no AA host is bound, Flutter shouldn't care.
class CarBridge {
  static const _channel = MethodChannel('kvm.car.bridge');

  CarBridge() {
    if (!_supported) return;
    _channel.setMethodCallHandler(_onCall);
  }

  void Function(double nx, double ny)? onClick;
  void Function(double dx, double dy)? onScroll;
  void Function()? onReload;

  bool get _supported => Platform.isAndroid;

  int _frameCount = 0;
  bool _everSucceeded = false;

  Future<void> pushFrame(Uint8List jpeg) async {
    if (!_supported) return;
    _frameCount++;
    try {
      await _channel.invokeMethod('pushFrame', {'jpeg': jpeg});
      if (!_everSucceeded) {
        _everSucceeded = true;
        // ignore: avoid_print
        print('[CarBridge] first pushFrame OK (#$_frameCount, ${jpeg.lengthInBytes}B)');
      }
    } catch (e) {
      if (_frameCount <= 3 || _frameCount % 60 == 0) {
        // ignore: avoid_print
        print('[CarBridge] pushFrame #$_frameCount failed: $e');
      }
    }
  }

  Future<void> clearFrame() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('clearFrame');
    } catch (_) {}
  }

  void dispose() {
    if (!_supported) return;
    _channel.setMethodCallHandler(null);
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'onClick':
        final args = call.arguments as Map?;
        final x = (args?['x'] as num?)?.toDouble();
        final y = (args?['y'] as num?)?.toDouble();
        if (x != null && y != null) onClick?.call(x, y);
        return null;
      case 'onScroll':
        final args = call.arguments as Map?;
        final dx = (args?['dx'] as num?)?.toDouble();
        final dy = (args?['dy'] as num?)?.toDouble();
        if (dx != null && dy != null) onScroll?.call(dx, dy);
        return null;
      case 'reload':
        onReload?.call();
        return null;
    }
    return null;
  }
}
