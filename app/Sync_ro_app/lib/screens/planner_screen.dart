import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../config/runtime_mode.dart';
import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../providers/schedule_controller.dart';
import '../providers/todo_controller.dart';
import '../services/planner_store.dart';
import 'detail_screen.dart';
import 'schedule_form_screen.dart';
import 'todo_screen.dart';

/// 할 일·일정 탭.
/// 위: 주간 시간표 (매주 반복 일정 + 이번 주 일정)
/// 아래: 이번 주 날짜 띠 + 그날 할 일 (날짜 없는 할 일은 "언제든")
class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key, this.onOpenScheduleRoutes});

  final ValueChanged<Schedule>? onOpenScheduleRoutes;

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

const _weekdayNames = ['월', '화', '수', '목', '금', '토', '일'];

/// 시간표 블록 색 (배경, 글자)
const _palette = <(Color, Color)>[
  (Color(0xFFEEEBFF), Color(0xFF4936D8)),
  (Color(0xFFE3F7EE), Color(0xFF0E7A52)),
  (Color(0xFFFFF3DC), Color(0xFF9A5C00)),
  (Color(0xFFFFE9EA), Color(0xFFC0373C)),
  (Color(0xFFE4F1FB), Color(0xFF1C6BA8)),
  (Color(0xFFF3E8FA), Color(0xFF8A3FB0)),
];

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _mondayOf(DateTime d) => _dateOnly(d).subtract(Duration(days: d.weekday - 1));
String _two(int v) => v.toString().padLeft(2, '0');
String _hmMinutes(int m) => '${_two(m ~/ 60)}:${_two(m % 60)}';
String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

class _PlannerScreenState extends State<PlannerScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final store = PlannerStore.instance;
  late DateTime _weekStart = _mondayOf(DateTime.now());
  late DateTime _selectedDay = _dateOnly(DateTime.now());
  /// 이번 주 일정 목록을 한 날로 좁혀 볼 때 (null = 이번 주 전체)
  DateTime? _filterDay;
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    store.addListener(_changed);
    RuntimeMode.instance.addListener(_modeChanged);
    store.ensureLoaded();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _modeChanged() => store.ensureLoaded();

  @override
  void dispose() {
    store.removeListener(_changed);
    RuntimeMode.instance.removeListener(_modeChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _moveWeek(int delta) => setState(() {
        _weekStart = _weekStart.add(Duration(days: 7 * delta));
        final today = _dateOnly(DateTime.now());
        final inWeek = !today.isBefore(_weekStart) && today.isBefore(_weekStart.add(const Duration(days: 7)));
        _selectedDay = inWeek ? today : _weekStart;
        _filterDay = null;
      });

  void _goToday() => setState(() {
        _weekStart = _mondayOf(DateTime.now());
        _selectedDay = _dateOnly(DateTime.now());
        _filterDay = null;
      });

  // ---------- 추가·수정 ----------

  Future<void> _openAddSheet({int? weekday, int? startMinutes}) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.repeat_rounded, color: AppTheme.primary),
            title: const Text('매주 반복 (시간표)'),
            subtitle: const Text('수업·출근·운동·분리수거처럼 매주 같은 요일·시간에 하는 일'),
            onTap: () => Navigator.pop(sheet, 'routine'),
          ),
          ListTile(
            leading: const Icon(Icons.event_rounded, color: AppTheme.primary),
            title: const Text('한 번만 있는 일정'),
            subtitle: const Text('장소와 도착 시간이 있으면 출발 시각을 계산해 줘요'),
            onTap: () => Navigator.pop(sheet, 'schedule'),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle_outline_rounded, color: AppTheme.primary),
            title: const Text('할 일'),
            subtitle: Text('${_selectedDay.month}/${_selectedDay.day}(${_weekdayNames[_selectedDay.weekday - 1]})에 할 일로 추가'),
            onTap: () => Navigator.pop(sheet, 'todo'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case 'routine':
        await _editRoutine(null, weekday: weekday ?? _selectedDay.weekday, startMinutes: startMinutes);
      case 'schedule':
        await _addSchedule();
      case 'todo':
        await _addTodo(_selectedDay);
    }
  }

  Future<void> _addSchedule() async {
    final saved = await Navigator.push<Schedule>(
      context,
      MaterialPageRoute(builder: (_) => const ScheduleFormScreen()),
    );
    if (saved != null && mounted) widget.onOpenScheduleRoutes?.call(saved);
  }

  Future<void> _addTodo(DateTime? day) async {
    final todo = await TodoScreen.showTodoDialog(context);
    if (todo != null) await store.setTodoDay(todo.id, day);
  }

  Future<void> _editRoutine(Routine? existing, {int? weekday, int? startMinutes}) async {
    final result = await showDialog<_RoutineResult>(
      context: context,
      builder: (_) => _RoutineDialog(existing: existing, weekday: weekday, startMinutes: startMinutes),
    );
    if (result == null) return;
    if (result.delete && existing != null) {
      await store.deleteRoutine(existing.id);
    } else if (result.routine != null) {
      await store.upsertRoutine(result.routine!);
    }
  }

  Future<void> _openSchedule(Schedule s) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            title: Text(s.title, style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text('${s.location} · ${s.startTime.month}/${s.startTime.day} ${_hm(s.startTime)}까지 도착'),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.route_rounded),
            title: const Text('이 일정으로 경로 추천'),
            onTap: () => Navigator.pop(sheet, 'route'),
          ),
          ListTile(leading: const Icon(Icons.info_outline), title: const Text('상세 보기'), onTap: () => Navigator.pop(sheet, 'detail')),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('수정'), onTap: () => Navigator.pop(sheet, 'edit')),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppTheme.danger),
            title: const Text('삭제', style: TextStyle(color: AppTheme.danger)),
            onTap: () => Navigator.pop(sheet, 'delete'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (!mounted || action == null) return;
    final controller = ScheduleScope.of(context);
    switch (action) {
      case 'route':
        widget.onOpenScheduleRoutes?.call(s);
      case 'detail':
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => DetailScreen(title: s.title, schedule: s, onOpenScheduleRoutes: widget.onOpenScheduleRoutes)));
      case 'edit':
        await Navigator.push<Schedule>(context, MaterialPageRoute(builder: (_) => ScheduleFormScreen(existing: s)));
      case 'delete':
        try {
          await controller.deleteSchedule(s.id);
        } catch (e) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('일정 삭제 실패: $e')));
        }
    }
  }

  Future<void> _todoMenu(TodoItem todo, String action) async {
    final controller = TodoScope.of(context);
    try {
      switch (action) {
        case 'edit':
          await TodoScreen.showTodoDialog(context, existing: todo);
        case 'delete':
          await controller.deleteTodo(todo.id);
          await store.setTodoDay(todo.id, null);
        case 'anytime':
          await store.setTodoDay(todo.id, null);
        case 'pick':
          final picked = await showDatePicker(
            context: context,
            initialDate: _selectedDay,
            firstDate: DateTime(_now.year - 1),
            lastDate: DateTime(_now.year + 2),
          );
          if (picked != null) await store.setTodoDay(todo.id, picked);
        default:
          if (action.startsWith('day:')) {
            await store.setTodoDay(todo.id, DateTime.parse(action.substring(4)));
          }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('할 일 변경 실패: $e')));
    }
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final schedules = ScheduleScope.of(context).schedules;
    final todoController = TodoScope.of(context);
    final todos = todoController.todos;
    final weekEnd = _weekStart.add(const Duration(days: 7));
    final weekSchedules = schedules
        .where((s) => !s.startTime.isBefore(_weekStart) && s.startTime.isBefore(weekEnd))
        .toList();

    weekSchedules.sort((a, b) => a.startTime.compareTo(b.startTime));
    final filterDay = _filterDay;
    final shownSchedules = filterDay == null
        ? weekSchedules
        : weekSchedules.where((s) => _dateOnly(s.startTime) == filterDay).toList();

    // 할 일: 이번 주에 날짜를 정한 것 + 날짜 없는 것
    final weekKeys = {for (var i = 0; i < 7; i++) PlannerStore.dayKey(_weekStart.add(Duration(days: i))): i};
    final weekTodos = todos.where((t) => weekKeys.containsKey(store.dayOf(t.id))).toList()
      ..sort((a, b) => weekKeys[store.dayOf(a.id)]!.compareTo(weekKeys[store.dayOf(b.id)]!));
    final anytime = todos.where((t) => store.dayOf(t.id) == null && !t.isCompleted).toList();
    String? dayLabel(TodoItem t) {
      final i = weekKeys[store.dayOf(t.id)];
      if (i == null) return null;
      final d = _weekStart.add(Duration(days: i));
      return '${_weekdayNames[i]} ${d.month}/${d.day}';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('할 일·일정'),
        actions: [
          IconButton(tooltip: '추가', onPressed: () => _openAddSheet(), icon: const Icon(Icons.add_rounded)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
        children: [
          // 주 이동
          Row(children: [
            IconButton(onPressed: () => _moveWeek(-1), icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(
              child: Text(
                '${_weekStart.year}년 ${_weekStart.month}월 ${_weekStart.day}일 – '
                '${weekEnd.subtract(const Duration(days: 1)).month}월 ${weekEnd.subtract(const Duration(days: 1)).day}일',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
            IconButton(onPressed: () => _moveWeek(1), icon: const Icon(Icons.chevron_right_rounded)),
            TextButton(onPressed: _goToday, child: const Text('오늘')),
          ]),
          const SizedBox(height: 4),

          // 1) 이번 주 일정: 한 번만 있는 일정 미리 보기
          _SectionHeader(
            title: '이번 주 일정',
            subtitle: '이번 주에 따로 잡힌 일정 (반복 아님)',
            actionLabel: '일정 추가',
            onAction: _addSchedule,
          ),
          _WeekStrip(
            weekStart: _weekStart,
            selected: filterDay,
            today: _dateOnly(_now),
            counts: {
              for (var i = 0; i < 7; i++)
                i: weekSchedules.where((s) => _dateOnly(s.startTime) == _weekStart.add(Duration(days: i))).length,
            },
            onSelect: (d) => setState(() => _filterDay = _filterDay == d ? null : d),
          ),
          const SizedBox(height: 8),
          _WeekSchedulePreview(
            schedules: shownSchedules,
            now: _now,
            filtered: filterDay != null,
            onTap: _openSchedule,
            onShowAll: () => setState(() => _filterDay = null),
          ),

          // 2) 시간표: 매주 반복되는 일정·할 일
          const SizedBox(height: 26),
          _SectionHeader(
            title: '시간표',
            subtitle: '매주 반복되는 일정과 할 일',
            actionLabel: '반복 추가',
            onAction: () => _editRoutine(null, weekday: _dateOnly(_now).weekday),
          ),
          _Timetable(
            weekStart: _weekStart,
            now: _now,
            routines: store.routines,
            schedules: const [],
            onTapRoutine: (r) => _editRoutine(r),
            onTapSchedule: _openSchedule,
            onTapEmpty: (weekday, minutes) => _editRoutine(null, weekday: weekday, startMinutes: minutes),
          ),
          const SizedBox(height: 6),
          Text(
            '빈 칸을 누르면 그 요일·시간에 반복 일정이나 할 일을 넣고, 블록을 누르면 고쳐요. 이 기기에만 저장돼요.'
            '${RuntimeMode.instance.isDemo ? ' (시연 모드 예시 시간표)' : ''}',
            style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
          ),

          // 3) 할 일 (한 번만 하는 일)
          const SizedBox(height: 26),
          _SectionHeader(
            title: '할 일',
            subtitle: '한 번만 하면 되는 일 · 날짜 없는 할 일은 이동 중 들를 곳 추천에 쓰여요',
            actionLabel: '할 일 추가',
            onAction: () => _addTodo(null),
          ),
          _TodoGroup(
            title: '이번 주에 할 일',
            empty: '이번 주로 날짜를 정한 할 일이 없어요. 할 일의 메뉴(⋮)에서 요일을 고를 수 있어요.',
            todos: weekTodos,
            weekStart: _weekStart,
            dayLabel: dayLabel,
            onToggle: (t) => todoController.toggleCompleted(t),
            onMenu: _todoMenu,
          ),
          const SizedBox(height: 14),
          _TodoGroup(
            title: '언제든',
            empty: '날짜 없는 할 일이 없어요.',
            todos: anytime,
            weekStart: _weekStart,
            onToggle: (t) => todoController.toggleCompleted(t),
            onMenu: _todoMenu,
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle, this.actionLabel, this.onAction});
  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
              if (subtitle != null)
                Text(subtitle!, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            ]),
          ),
          if (actionLabel != null && onAction != null)
            TextButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(actionLabel!),
            ),
        ]),
      );
}

/// 이번 주 일정 간략 목록: 요일 · 시각 · 제목 · 장소
class _WeekSchedulePreview extends StatelessWidget {
  const _WeekSchedulePreview({
    required this.schedules,
    required this.now,
    required this.filtered,
    required this.onTap,
    required this.onShowAll,
  });

  final List<Schedule> schedules;
  final DateTime now;
  final bool filtered;
  final ValueChanged<Schedule> onTap;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    if (schedules.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          Expanded(
            child: Text(filtered ? '이 날은 따로 잡힌 일정이 없어요.' : '이번 주에 따로 잡힌 일정이 없어요.',
                style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
          ),
          if (filtered) TextButton(onPressed: onShowAll, child: const Text('전체 보기')),
        ]),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        for (var i = 0; i < schedules.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 64),
          Builder(builder: (context) {
            final s = schedules[i];
            final past = s.endTime.isBefore(now);
            final isToday = _dateOnly(s.startTime) == _dateOnly(now);
            return InkWell(
              onTap: () => onTap(s),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                child: Row(children: [
                  SizedBox(
                    width: 44,
                    child: Column(children: [
                      Text(_weekdayNames[s.startTime.weekday - 1],
                          style: TextStyle(fontSize: 11, color: isToday ? AppTheme.primary : AppTheme.textMuted)),
                      Text('${s.startTime.day}',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: past ? AppTheme.textMuted : (isToday ? AppTheme.primary : AppTheme.textStrong))),
                    ]),
                  ),
                  Container(
                    width: 3,
                    height: 34,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: past ? AppTheme.border : AppTheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: past ? AppTheme.textMuted : AppTheme.textStrong,
                            decoration: s.isCompleted ? TextDecoration.lineThrough : null,
                          )),
                      Text('${_hm(s.startTime)}까지 도착 · ${s.location}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
                ]),
              ),
            );
          }),
        ],
      ]),
    );
  }
}

// ======================================================================
// 주간 시간표
// ======================================================================

class _Block {
  _Block({required this.weekday, required this.start, required this.end, required this.title,
      required this.sub, required this.colors, this.routine, this.schedule});
  final int weekday;
  final int start;
  final int end;
  final String title;
  final String sub;
  final (Color, Color) colors;
  final Routine? routine;
  final Schedule? schedule;
  int lane = 0;
  int lanes = 1;
}

class _Timetable extends StatelessWidget {
  const _Timetable({
    required this.weekStart,
    required this.now,
    required this.routines,
    required this.schedules,
    required this.onTapRoutine,
    required this.onTapSchedule,
    required this.onTapEmpty,
  });

  final DateTime weekStart;
  final DateTime now;
  final List<Routine> routines;
  final List<Schedule> schedules;
  final ValueChanged<Routine> onTapRoutine;
  final ValueChanged<Schedule> onTapSchedule;
  final void Function(int weekday, int minutes) onTapEmpty;

  static const double hourHeight = 46;
  static const double timeColumn = 30;
  static const double headerHeight = 44;

  List<_Block> _blocks() {
    final out = <_Block>[];
    for (final r in routines) {
      for (final d in r.weekdays) {
        out.add(_Block(
          weekday: d,
          start: r.startMinutes,
          end: r.endMinutes > r.startMinutes ? r.endMinutes : r.startMinutes + 30,
          title: r.title,
          sub: r.location,
          colors: _palette[r.colorIndex % _palette.length],
          routine: r,
        ));
      }
    }
    for (final s in schedules) {
      final start = s.startTime.hour * 60 + s.startTime.minute;
      final sameDay = s.endTime.year == s.startTime.year &&
          s.endTime.month == s.startTime.month && s.endTime.day == s.startTime.day;
      final endRaw = sameDay ? s.endTime.hour * 60 + s.endTime.minute : 24 * 60;
      out.add(_Block(
        weekday: s.startTime.weekday,
        start: start,
        end: endRaw > start ? endRaw : start + 60,
        title: s.title,
        sub: s.location,
        colors: (AppTheme.textStrong, Colors.white),
        schedule: s,
      ));
    }
    // 같은 요일에 겹치면 나란히 놓아요
    for (var d = 1; d <= 7; d++) {
      final day = out.where((b) => b.weekday == d).toList()..sort((a, b) => a.start.compareTo(b.start));
      final group = <_Block>[];
      var groupEnd = -1;
      void flush() {
        final laneEnds = <int>[];
        for (final b in group) {
          var lane = laneEnds.indexWhere((e) => e <= b.start);
          if (lane < 0) {
            laneEnds.add(b.end);
            lane = laneEnds.length - 1;
          } else {
            laneEnds[lane] = b.end;
          }
          b.lane = lane;
        }
        for (final b in group) {
          b.lanes = laneEnds.length;
        }
        group.clear();
      }
      for (final b in day) {
        if (group.isNotEmpty && b.start >= groupEnd) flush();
        group.add(b);
        if (b.end > groupEnd) groupEnd = b.end;
      }
      if (group.isNotEmpty) flush();
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final blocks = _blocks();
    var startHour = 8, endHour = 22;
    for (final b in blocks) {
      if (b.start ~/ 60 < startHour) startHour = b.start ~/ 60;
      final eh = (b.end + 59) ~/ 60;
      if (eh > endHour) endHour = eh.clamp(0, 24).toInt();
    }
    final hours = endHour - startHour;
    final today = _dateOnly(now);
    final todayIndex = today.difference(weekStart).inDays;
    final bodyHeight = hours * hourHeight;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(builder: (context, c) {
        final colWidth = (c.maxWidth - timeColumn) / 7;
        return Column(children: [
          // 요일 머리
          SizedBox(
            height: headerHeight,
            child: Row(children: [
              const SizedBox(width: timeColumn),
              for (var i = 0; i < 7; i++)
                SizedBox(
                  width: colWidth,
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(_weekdayNames[i],
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: i == todayIndex ? AppTheme.primary : (i >= 5 ? AppTheme.danger : AppTheme.textMuted))),
                    const SizedBox(height: 2),
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: i == todayIndex ? AppTheme.primary : Colors.transparent,
                        shape: BoxShape.circle,
                      ),
                      child: Text('${weekStart.add(Duration(days: i)).day}',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: i == todayIndex ? Colors.white : AppTheme.textStrong)),
                    ),
                  ]),
                ),
            ]),
          ),
          const Divider(height: 1),
          SizedBox(
            height: bodyHeight,
            child: Stack(children: [
              // 오늘 열 배경
              if (todayIndex >= 0 && todayIndex < 7)
                Positioned(
                  left: timeColumn + colWidth * todayIndex,
                  top: 0,
                  bottom: 0,
                  width: colWidth,
                  child: Container(color: AppTheme.primarySoft.withValues(alpha: 0.45)),
                ),
              // 시간 줄 + 시각
              for (var h = 0; h < hours; h++) ...[
                Positioned(
                  left: timeColumn,
                  right: 0,
                  top: h * hourHeight,
                  child: Container(height: 1, color: AppTheme.border),
                ),
                Positioned(
                  left: 0,
                  width: timeColumn - 4,
                  top: h * hourHeight + 2,
                  child: Text('${startHour + h}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                ),
              ],
              // 세로 줄
              for (var i = 0; i < 7; i++)
                Positioned(
                  left: timeColumn + colWidth * i,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 1, color: AppTheme.border.withValues(alpha: 0.6)),
                ),
              // 빈 칸 누르기
              for (var i = 0; i < 7; i++)
                Positioned(
                  left: timeColumn + colWidth * i,
                  top: 0,
                  width: colWidth,
                  height: bodyHeight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (d) {
                      final minutes = startHour * 60 + (d.localPosition.dy / hourHeight * 60).floor();
                      onTapEmpty(i + 1, (minutes ~/ 30) * 30);
                    },
                  ),
                ),
              // 블록
              for (final b in blocks)
                Positioned(
                  left: timeColumn + colWidth * (b.weekday - 1) + 1.5 + (colWidth - 3) * b.lane / b.lanes,
                  width: (colWidth - 3) / b.lanes - 1,
                  top: (b.start - startHour * 60) / 60 * hourHeight + 1,
                  height: ((b.end - b.start) / 60 * hourHeight - 2).clamp(16, double.infinity).toDouble(),
                  child: GestureDetector(
                    onTap: () {
                      if (b.routine != null) onTapRoutine(b.routine!);
                      if (b.schedule != null) onTapSchedule(b.schedule!);
                    },
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(3, 3, 2, 2),
                      decoration: BoxDecoration(
                        color: b.routine?.isTodo == true ? Colors.white : b.colors.$1,
                        borderRadius: BorderRadius.circular(6),
                        border: b.schedule != null
                            ? null
                            : b.routine?.isTodo == true
                                ? Border.all(color: b.colors.$2, width: 1.2)
                                : Border(left: BorderSide(color: b.colors.$2, width: 2.5)),
                      ),
                      child: ClipRect(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(b.routine?.isTodo == true ? '✓ ${b.title}' : b.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 10,
                                  height: 1.15,
                                  fontWeight: FontWeight.w800,
                                  color: b.schedule != null ? Colors.white : b.colors.$2)),
                          if (b.sub.isNotEmpty && b.end - b.start >= 50)
                            Text(b.sub,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 9,
                                    height: 1.1,
                                    color: b.schedule != null ? Colors.white70 : b.colors.$2.withValues(alpha: 0.8))),
                        ]),
                      ),
                    ),
                  ),
                ),
              // 지금 시각 줄
              if (todayIndex >= 0 && todayIndex < 7)
                Builder(builder: (context) {
                  final m = now.hour * 60 + now.minute - startHour * 60;
                  if (m < 0 || m > hours * 60) return const SizedBox.shrink();
                  final top = m / 60 * hourHeight;
                  return Positioned(
                    left: timeColumn + colWidth * todayIndex - 3,
                    width: colWidth + 3,
                    top: top - 3,
                    child: IgnorePointer(
                      child: Row(children: [
                        Container(width: 6, height: 6, decoration: const BoxDecoration(color: AppTheme.danger, shape: BoxShape.circle)),
                        Expanded(child: Container(height: 1.5, color: AppTheme.danger)),
                      ]),
                    ),
                  );
                }),
            ]),
          ),
        ]);
      }),
    );
  }
}

// ======================================================================
// 할 일
// ======================================================================

class _WeekStrip extends StatelessWidget {
  const _WeekStrip({
    required this.weekStart,
    required this.selected,
    required this.today,
    required this.counts,
    required this.onSelect,
  });

  final DateTime weekStart;
  final DateTime? selected;
  final DateTime today;
  final Map<int, int> counts;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      for (var i = 0; i < 7; i++)
        Expanded(
          child: Builder(builder: (context) {
            final day = weekStart.add(Duration(days: i));
            final isSel = day == selected;
            final isToday = day == today;
            final count = counts[i] ?? 0;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Material(
                color: isSel ? AppTheme.primary : Colors.white,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => onSelect(day),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: isSel ? AppTheme.primary : (isToday ? AppTheme.primary : AppTheme.border)),
                    ),
                    child: Column(children: [
                      Text(_weekdayNames[i],
                          style: TextStyle(fontSize: 11, color: isSel ? Colors.white70 : AppTheme.textMuted)),
                      const SizedBox(height: 2),
                      Text('${day.day}',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w800, color: isSel ? Colors.white : AppTheme.textStrong)),
                      const SizedBox(height: 3),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: count == 0 ? Colors.transparent : (isSel ? Colors.white : AppTheme.primary),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            );
          }),
        ),
    ]);
  }
}

class _TodoGroup extends StatelessWidget {
  const _TodoGroup({
    required this.title,
    required this.empty,
    required this.todos,
    required this.weekStart,
    required this.onToggle,
    required this.onMenu,
    this.dayLabel,
  });

  final String title;
  final String? Function(TodoItem todo)? dayLabel;
  final String empty;
  final List<TodoItem> todos;
  final DateTime weekStart;
  final ValueChanged<TodoItem> onToggle;
  final void Function(TodoItem todo, String action) onMenu;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Text('${todos.length}개', style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ]),
      ),
      if (todos.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border),
          ),
          child: Text(empty, style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
        )
      else
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(children: [
            for (var i = 0; i < todos.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 52),
              _TodoRow(todo: todos[i], weekStart: weekStart, day: dayLabel?.call(todos[i]), onToggle: onToggle, onMenu: onMenu),
            ],
          ]),
        ),
    ]);
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({required this.todo, required this.weekStart, required this.onToggle, required this.onMenu, this.day});
  final TodoItem todo;
  final String? day;
  final DateTime weekStart;
  final ValueChanged<TodoItem> onToggle;
  final void Function(TodoItem todo, String action) onMenu;

  @override
  Widget build(BuildContext context) {
    final done = todo.isCompleted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(children: [
        Checkbox(
          value: done,
          onChanged: (_) => onToggle(todo),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        Icon(todo.requiresTravel ? Icons.add_location_alt_outlined : Icons.task_alt_rounded,
            size: 18, color: done ? AppTheme.textMuted : AppTheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(todo.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: done ? AppTheme.textMuted : AppTheme.textStrong,
                  decoration: done ? TextDecoration.lineThrough : null,
                )),
            Text(
              '${day == null ? '' : '$day · '}예상 ${todo.estimatedMinutes}분${todo.requiresTravel ? ' · ${todo.placeName?.isNotEmpty == true ? todo.placeName : '가는 길에 들르기'}' : ''}',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
          ]),
        ),
        PopupMenuButton<String>(
          tooltip: '할 일 메뉴',
          onSelected: (v) => onMenu(todo, v),
          itemBuilder: (_) => [
            for (var i = 0; i < 7; i++)
              PopupMenuItem(
                value: 'day:${PlannerStore.dayKey(weekStart.add(Duration(days: i)))}',
                child: Text('${_weekdayNames[i]}요일 (${weekStart.add(Duration(days: i)).month}/${weekStart.add(Duration(days: i)).day})로 옮기기'),
              ),
            const PopupMenuItem(value: 'pick', child: Text('다른 날짜 고르기…')),
            const PopupMenuItem(value: 'anytime', child: Text('날짜 없이 (언제든)')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'edit', child: Text('수정')),
            const PopupMenuItem(value: 'delete', child: Text('삭제', style: TextStyle(color: AppTheme.danger))),
          ],
        ),
      ]),
    );
  }
}

// ======================================================================
// 반복 일정 입력 창
// ======================================================================

class _RoutineResult {
  const _RoutineResult({this.routine, this.delete = false});
  final Routine? routine;
  final bool delete;
}

class _RoutineDialog extends StatefulWidget {
  const _RoutineDialog({this.existing, this.weekday, this.startMinutes});
  final Routine? existing;
  final int? weekday;
  final int? startMinutes;

  @override
  State<_RoutineDialog> createState() => _RoutineDialogState();
}

class _RoutineDialogState extends State<_RoutineDialog> {
  late final TextEditingController _title = TextEditingController(text: widget.existing?.title ?? '');
  late final TextEditingController _location = TextEditingController(text: widget.existing?.location ?? '');
  late final Set<int> _days = {...?widget.existing?.weekdays, if (widget.existing == null) widget.weekday ?? DateTime.now().weekday};
  late int _start = widget.existing?.startMinutes ?? widget.startMinutes ?? 9 * 60;
  late int _end = widget.existing?.endMinutes ?? (_start + 60).clamp(0, 24 * 60 - 1).toInt();
  late int _color = widget.existing?.colorIndex ?? 0;
  late bool _isTodo = widget.existing?.isTodo ?? false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _pick(bool start) async {
    final current = start ? _start : _end;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
    );
    if (t == null) return;
    setState(() {
      final m = t.hour * 60 + t.minute;
      if (start) {
        final length = _end - _start;
        _start = m;
        _end = (m + (length > 0 ? length : 60)).clamp(0, 24 * 60 - 1).toInt();
      } else {
        _end = m;
      }
    });
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return setState(() => _error = '이름을 입력해 주세요.');
    if (_days.isEmpty) return setState(() => _error = '요일을 하나 이상 골라 주세요.');
    if (_end <= _start) return setState(() => _error = '끝나는 시간이 시작보다 늦어야 해요.');
    Navigator.pop(
      context,
      _RoutineResult(
        routine: Routine(
          id: widget.existing?.id ?? PlannerStore.instance.newRoutineId(),
          title: title,
          location: _location.text.trim(),
          weekdays: (_days.toList()..sort()),
          startMinutes: _start,
          endMinutes: _end,
          colorIndex: _color,
          isTodo: _isTodo,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '매주 반복' : '반복 수정'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('일정'), icon: Icon(Icons.event_repeat_rounded)),
                ButtonSegment(value: true, label: Text('할 일'), icon: Icon(Icons.task_alt_rounded)),
              ],
              selected: {_isTodo},
              onSelectionChanged: (v) => setState(() => _isTodo = v.first),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _title,
            decoration: InputDecoration(labelText: _isTodo ? '할 일 (예: 분리수거, 빨래)' : '이름 (예: 전공 수업, 헬스)'),
          ),
          const SizedBox(height: 10),
          TextField(controller: _location, decoration: const InputDecoration(labelText: '장소 (선택)')),
          const SizedBox(height: 14),
          const Text('요일', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (var d = 1; d <= 7; d++)
              FilterChip(
                showCheckmark: false,
                label: Text(_weekdayNames[d - 1]),
                selected: _days.contains(d),
                selectedColor: AppTheme.primarySoft,
                onSelected: (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
              ),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            ActionChip(label: const Text('평일'), onPressed: () => setState(() => _days..clear()..addAll([1, 2, 3, 4, 5]))),
            ActionChip(label: const Text('매일'), onPressed: () => setState(() => _days..clear()..addAll([1, 2, 3, 4, 5, 6, 7]))),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => _pick(true), child: Text('시작 ${_hmMinutes(_start)}'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: () => _pick(false), child: Text('끝 ${_hmMinutes(_end)}'))),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            for (var i = 0; i < _palette.length; i++)
              GestureDetector(
                onTap: () => setState(() => _color = i),
                child: Container(
                  width: 28,
                  height: 28,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: _palette[i].$1,
                    shape: BoxShape.circle,
                    border: Border.all(color: _palette[i].$2, width: _color == i ? 3 : 1),
                  ),
                ),
              ),
          ]),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          ],
        ]),
      ),
      actions: [
        if (widget.existing != null)
          TextButton(
            onPressed: () => Navigator.pop(context, const _RoutineResult(delete: true)),
            child: const Text('삭제', style: TextStyle(color: AppTheme.danger)),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(onPressed: _save, child: const Text('저장')),
      ],
    );
  }
}
