import '../config/runtime_mode.dart';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/schedule.dart';

class ScheduleStorageService {
  static String get _key => RuntimeMode.instance.isDemo
      ? 'sync_ro_schedules_v1' : 'sync_ro_schedules_v2_${RuntimeMode.instance.storageNamespace}';

  Future<List<Schedule>?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);

    if (raw == null) return null;

    final list = jsonDecode(raw) as List;

    return list
        .map(
          (item) => Schedule.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  Future<void> save(List<Schedule> schedules) async {
    final prefs = await SharedPreferences.getInstance();

    final raw = jsonEncode(schedules.map((e) => e.toJson()).toList());

    if (!await prefs.setString(_key, raw)) {
      throw Exception('일정 저장에 실패했습니다.');
    }
  }
}
