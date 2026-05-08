import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/device.dart';
import 'credential_store.dart';

class DeviceStore extends ChangeNotifier {
  static const _key = 'kvm.devices';

  final SharedPreferences _prefs;
  final List<Device> _devices = [];

  DeviceStore._(this._prefs);

  static Future<DeviceStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = DeviceStore._(prefs);
    final raw = prefs.getString(_key);
    if (raw != null) {
      final list = jsonDecode(raw) as List;
      s._devices.addAll(
        list.map((j) => Device.fromJson(j as Map<String, dynamic>)),
      );
    }
    return s;
  }

  List<Device> get devices => List.unmodifiable(_devices);

  Future<void> add(Device d) async {
    _devices.add(d);
    await _persist();
    notifyListeners();
  }

  Future<void> update(Device d) async {
    final i = _devices.indexWhere((x) => x.id == d.id);
    if (i < 0) return;
    _devices[i] = d;
    await _persist();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _devices.removeWhere((d) => d.id == id);
    await CredentialStore.deletePassword(id);
    await _persist();
    notifyListeners();
  }

  Future<void> _persist() async {
    final raw = jsonEncode(_devices.map((d) => d.toJson()).toList());
    await _prefs.setString(_key, raw);
  }
}
