import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/runtime_mode.dart';

/// 매주 반복되는 일정·할 일 (수업, 출근, 운동, 분리수거 …). 지금은 이 기기에만 저장해요.
/// 서버 일정 API에 반복 필드가 생기면 그쪽으로 옮겨요.
class Routine {
  const Routine({
    required this.id,
    required this.title,
    required this.weekdays,
    required this.startMinutes,
    required this.endMinutes,
    this.location = '',
    this.colorIndex = 0,
    this.isTodo = false,
  });

  /// true 면 반복 할 일 (예: 매주 화요일 분리수거), false 면 반복 일정
  final bool isTodo;

  final int id;
  final String title;
  final String location;
  /// 1 = 월요일 … 7 = 일요일 (DateTime.weekday 와 같아요)
  final List<int> weekdays;
  /// 자정부터 몇 분 (예: 9:30 → 570)
  final int startMinutes;
  final int endMinutes;
  final int colorIndex;

  Routine copyWith({
    String? title,
    String? location,
    List<int>? weekdays,
    int? startMinutes,
    int? endMinutes,
    int? colorIndex,
    bool? isTodo,
  }) =>
      Routine(
        id: id,
        title: title ?? this.title,
        location: location ?? this.location,
        weekdays: weekdays ?? this.weekdays,
        startMinutes: startMinutes ?? this.startMinutes,
        endMinutes: endMinutes ?? this.endMinutes,
        colorIndex: colorIndex ?? this.colorIndex,
        isTodo: isTodo ?? this.isTodo,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'location': location,
        'weekdays': weekdays,
        'start': startMinutes,
        'end': endMinutes,
        'color': colorIndex,
        'todo': isTodo,
      };

  static Routine? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final days = raw['weekdays'];
    if (raw['id'] is! num || raw['start'] is! num || raw['end'] is! num || days is! List) return null;
    return Routine(
      id: (raw['id'] as num).toInt(),
      title: '${raw['title'] ?? ''}',
      location: '${raw['location'] ?? ''}',
      weekdays: days.whereType<num>().map((e) => e.toInt()).where((d) => d >= 1 && d <= 7).toList(),
      startMinutes: (raw['start'] as num).toInt(),
      endMinutes: (raw['end'] as num).toInt(),
      colorIndex: (raw['color'] as num?)?.toInt() ?? 0,
      isTodo: raw['todo'] == true,
    );
  }
}

/// 할 일·일정 탭 전용 저장소: 반복 일정 + "할 일을 어느 날 할지".
/// 모드(시연/실제)마다 따로 저장해요.
class PlannerStore extends ChangeNotifier {
  PlannerStore._();
  static final PlannerStore instance = PlannerStore._();

  static const _routineKey = 'sync_ro_routines_v1';
  static const _todoDayKey = 'sync_ro_todo_days_v1';

  String? _namespace;
  bool _loading = false;
  List<Routine> _routines = [];
  Map<int, String> _todoDays = {};

  List<Routine> get routines => List.unmodifiable(_routines);
  bool get isLoaded => _namespace == RuntimeMode.instance.storageNamespace;

  String _key(String base) => '${base}_${RuntimeMode.instance.storageNamespace}';

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 모드가 바뀌었으면 그 모드의 데이터로 다시 읽어요.
  Future<void> ensureLoaded() async {
    final ns = RuntimeMode.instance.storageNamespace;
    if (_namespace == ns || _loading) return;
    _loading = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawRoutines = prefs.getString(_key(_routineKey));
      final rawDays = prefs.getString(_key(_todoDayKey));
      final routines = <Routine>[];
      if (rawRoutines != null) {
        final list = jsonDecode(rawRoutines);
        if (list is List) {
          for (final item in list) {
            final r = Routine.fromJson(item);
            if (r != null) routines.add(r);
          }
        }
      } else if (RuntimeMode.instance.isDemo) {
        routines.addAll(_demoRoutines);
      }
      final days = <int, String>{};
      if (rawDays != null) {
        final map = jsonDecode(rawDays);
        if (map is Map) {
          map.forEach((k, v) {
            final id = int.tryParse('$k');
            if (id != null && v is String) days[id] = v;
          });
        }
      }
      _routines = routines;
      _todoDays = days;
      _namespace = ns;
    } catch (_) {
      _routines = RuntimeMode.instance.isDemo ? List.of(_demoRoutines) : [];
      _todoDays = {};
      _namespace = ns;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> _save() async {
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(_routineKey), jsonEncode(_routines.map((r) => r.toJson()).toList()));
    await prefs.setString(_key(_todoDayKey), jsonEncode(_todoDays.map((k, v) => MapEntry('$k', v))));
  }

  Future<void> upsertRoutine(Routine routine) async {
    final i = _routines.indexWhere((r) => r.id == routine.id);
    if (i >= 0) {
      _routines[i] = routine;
    } else {
      _routines.add(routine);
    }
    await _save();
  }

  Future<void> deleteRoutine(int id) async {
    _routines.removeWhere((r) => r.id == id);
    await _save();
  }

  int newRoutineId() => DateTime.now().millisecondsSinceEpoch;

  List<Routine> routinesOn(int weekday) =>
      _routines.where((r) => r.weekdays.contains(weekday)).toList()
        ..sort((a, b) => a.startMinutes.compareTo(b.startMinutes));

  /// 할 일을 할 날짜. null 이면 "언제든".
  String? dayOf(int todoId) => _todoDays[todoId];

  Future<void> setTodoDay(int todoId, DateTime? day) async {
    if (day == null) {
      _todoDays.remove(todoId);
    } else {
      _todoDays[todoId] = dayKey(day);
    }
    await _save();
  }

  /// 시연 모드 처음 실행 때만 보여 주는 예시 시간표
  static const _demoRoutines = <Routine>[
    Routine(id: 1, title: '전공 수업', location: '고려대 공학관', weekdays: [1, 3], startMinutes: 9 * 60, endMinutes: 10 * 60 + 15, colorIndex: 0),
    Routine(id: 2, title: '교양 수업', location: '고려대 국제관', weekdays: [2, 4], startMinutes: 13 * 60, endMinutes: 14 * 60 + 15, colorIndex: 1),
    Routine(id: 3, title: '헬스', location: '학교 체육관', weekdays: [1, 3, 5], startMinutes: 19 * 60, endMinutes: 20 * 60, colorIndex: 2),
    Routine(id: 4, title: '카페 아르바이트', location: '안암역 앞', weekdays: [6], startMinutes: 11 * 60, endMinutes: 16 * 60, colorIndex: 3),
    Routine(id: 5, title: '분리수거', weekdays: [2], startMinutes: 21 * 60, endMinutes: 21 * 60 + 30, colorIndex: 4, isTodo: true),
  ];
}
