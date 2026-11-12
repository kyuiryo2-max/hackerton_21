import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Application-level mode and per-installation identity.
/// Installation IDs are for UX partitioning only, NOT authentication.
class RuntimeMode extends ChangeNotifier {
  RuntimeMode._();
  static final RuntimeMode instance = RuntimeMode._();
  static const _modeKey = 'sync_ro_mode_v1';
  static const _identityKey = 'sync_ro_installation_id_v1';
  bool _demo = true;
  String _installationId = '';
  bool get isDemo => _demo;
  String get installationId => _installationId;
  String get userId => _demo ? 'demo' : _installationId;
  String get storageNamespace => _demo ? 'demo' : _installationId;

  Future<void> initialize({bool defaultDemo = true}) async {
    final prefs = await SharedPreferences.getInstance();
    _demo = prefs.getBool(_modeKey) ?? defaultDemo;
    final saved = prefs.getString(_identityKey);
    if (saved != null && saved.isNotEmpty) {
      _installationId = saved;
    } else {
      final random = Random.secure();
      final bytes = List<int>.generate(16, (_) => random.nextInt(256));
      // UUID v4, generated once per browser/device installation.
      bytes[6] = (bytes[6] & 0x0f) | 0x40;
      bytes[8] = (bytes[8] & 0x3f) | 0x80;
      final value = bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
      _installationId = '${value.substring(0, 8)}-${value.substring(8, 12)}-'
          '${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
      await prefs.setString(_identityKey, _installationId);
    }
    notifyListeners();
  }

  Future<void> changeMode(bool demo) async {
    if (_demo == demo) return;
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setBool(_modeKey, demo)) {
      throw StateError('모드 설정 저장 실패');
    }
    _demo = demo;
    notifyListeners();
  }
}
