import 'dart:io';

import 'package:flutter/services.dart';

/// Linux-only bridge for native window operations that Flutter doesn't
/// expose. SystemChrome.setEnabledSystemUIMode is Android-only; on Linux
/// "fullscreen" needs to actually call gtk_window_fullscreen() in the C++
/// runner so the title bar / header bar gets hidden.
///
/// All methods are no-ops on platforms other than Linux.
class WindowBridge {
  static const _channel = MethodChannel('kvm/window');

  static Future<void> setFullscreen(bool fullscreen) async {
    if (!Platform.isLinux) return;
    try {
      await _channel.invokeMethod<bool>('setFullscreen', fullscreen);
    } on MissingPluginException {
      // Older runner without the channel — silently ignore so debug builds
      // don't crash before a recompile.
    }
  }
}
