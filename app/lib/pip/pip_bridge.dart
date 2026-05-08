import 'dart:io';

import 'package:flutter/services.dart';

/// Talks to the Android Activity's Picture-in-Picture controls.
///
/// Three Flutter-side calls:
///   * [setReady]   — toggle whether the Activity should drop into PiP on
///                    Home press / nav-up gesture (`onUserLeaveHint`).
///   * [setAspect]  — declare the video aspect so PiP frames the content.
///   * [enter]      — explicit, immediate PiP transition.
///
/// One callback:
///   * [onModeChanged] — fired after `onPictureInPictureModeChanged` on the
///                      Android side, so the UI can hide chrome in PiP.
class PipBridge {
  static const _channel = MethodChannel('kvm.pip.bridge');

  PipBridge() {
    if (_supported) _channel.setMethodCallHandler(_onCall);
  }

  void Function(bool inPip)? onModeChanged;

  bool get _supported => Platform.isAndroid;

  Future<void> setReady(bool ready) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('setReady', {'ready': ready});
    } catch (_) {}
  }

  Future<void> setAspect(int width, int height) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod(
          'setAspect', {'width': width, 'height': height});
    } catch (_) {}
  }

  Future<bool> enter() async {
    if (!_supported) return false;
    try {
      final r = await _channel.invokeMethod<bool>('enter');
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    if (!_supported) return;
    _channel.setMethodCallHandler(null);
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'modeChanged') {
      final inPip = (call.arguments as Map?)?['inPip'] as bool? ?? false;
      onModeChanged?.call(inPip);
    }
    return null;
  }
}
