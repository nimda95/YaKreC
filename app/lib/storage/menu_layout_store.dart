import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where a single menu action should appear. Both flags can be true (action
/// shows in popup *and* toolbar) or both false (hidden from both — only
/// reachable via shortcut, if any).
class MenuActionPlacement {
  final bool popup;
  final bool toolbar;
  const MenuActionPlacement({required this.popup, required this.toolbar});

  static const defaultPlacement = MenuActionPlacement(popup: true, toolbar: false);

  MenuActionPlacement copyWith({bool? popup, bool? toolbar}) =>
      MenuActionPlacement(
        popup: popup ?? this.popup,
        toolbar: toolbar ?? this.toolbar,
      );

  Map<String, dynamic> toJson() => {'popup': popup, 'toolbar': toolbar};

  factory MenuActionPlacement.fromJson(Map<String, dynamic> j) =>
      MenuActionPlacement(
        popup: j['popup'] as bool? ?? true,
        toolbar: j['toolbar'] as bool? ?? false,
      );
}

/// A user-customised menu layout. Maps menu-action ids (the stable string
/// names from the `_MenuAction` enum) to where they should appear. Missing
/// keys fall back to [MenuActionPlacement.defaultPlacement] (popup, not
/// toolbar) so previously-stored layouts don't need migrations when new
/// actions are added.
class MenuLayout extends ChangeNotifier {
  final Map<String, MenuActionPlacement> _map;

  MenuLayout._(Map<String, MenuActionPlacement> map) : _map = {...map};

  factory MenuLayout.empty() => MenuLayout._(const {});

  MenuActionPlacement placementFor(String actionId) =>
      _map[actionId] ?? MenuActionPlacement.defaultPlacement;

  bool inPopup(String actionId) => placementFor(actionId).popup;
  bool inToolbar(String actionId) => placementFor(actionId).toolbar;

  Future<void> setPlacement(String actionId, MenuActionPlacement p) async {
    _map[actionId] = p;
    notifyListeners();
    await MenuLayoutStore._save(this);
  }

  Future<void> reset() async {
    _map.clear();
    notifyListeners();
    await MenuLayoutStore._save(this);
  }

  Map<String, dynamic> toJson() =>
      _map.map((k, v) => MapEntry(k, v.toJson()));

  factory MenuLayout._fromJson(Map<String, dynamic> j) {
    final map = <String, MenuActionPlacement>{};
    j.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        map[k] = MenuActionPlacement.fromJson(v);
      }
    });
    return MenuLayout._(map);
  }
}

class MenuLayoutStore {
  static const _key = 'kvm.menu_layout';

  static Future<MenuLayout> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return MenuLayout.empty();
    try {
      return MenuLayout._fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return MenuLayout.empty();
    }
  }

  static Future<void> _save(MenuLayout layout) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(layout.toJson()));
  }
}
