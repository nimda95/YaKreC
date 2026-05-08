import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide light/dark/system theme switch. Persisted via SharedPreferences
/// so the user's choice survives restarts, exposed as a [ChangeNotifier]
/// for [Provider] / [Consumer] consumers in the widget tree.
class ThemeController extends ChangeNotifier {
  static const _prefsKey = 'kvm.themeMode';

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  /// Hydrates [_mode] from SharedPreferences. Call once at app start.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _mode = ThemeMode.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => ThemeMode.system,
    );
    notifyListeners();
  }

  Future<void> setMode(ThemeMode m) async {
    if (m == _mode) return;
    _mode = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, m.name);
    notifyListeners();
  }
}
