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

/// 할 일·일정 탭 (11/13 개편, 규리 님 스케치)
///
/// [일정 | 할 일] 두 탭으로 나눠요.
/// - 일정: 정해진 시각까지 가야 하는 곳. 장소 + 도착 목표 시각. "경로 보기"로 이동 탭에 이어져요.
/// - 할 일: 가는 길에 해치울 일. 문장 하나만 쓰면 AI가 장소 종류를 붙이고, 머무는 시간은 장소별 기본값.
///   시간·요일·반복은 없어요. 이번 이동에 넣는 건 이동 탭의 "할 일 적용하기"에서 골라요.
///
/// 일정 탭에는 장우 님이 만든 주간 달력(주 이동 + 요일 띠)과 시간표(매주 반복)를 그대로 두었어요.
class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key, this.onOpenScheduleRoutes});

  final ValueChanged<Schedule>? onOpenScheduleRoutes;

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

/// 서버 data/demo/place_types.csv 와 같은 목록이에요.
const kPlaceTypes = [
  '편의점', '다이소', '약국', '카페', '빵집', '케이크집', '꽃집', '올리브영',
  '마트', '프린트', '우체국', '은행·ATM', '안경점', '음식점', '병원',
];

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

/// "오늘", "내일", "11월 14일 (금)"
String _dayLabel(DateTime d, DateTime now) {
  final diff = _dateOnly(d).difference(_dateOnly(now)).inDays;
  if (diff == 0) return '오늘';
  if (diff == 1) return '내일';
  return '${d.month}월 ${d.day}일 (${_weekdayNames[d.weekday - 1]})';
}

class _PlannerScreenState extends State<PlannerScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  int _tab = 0; // 0 일정, 1 할 일
  final store = PlannerStore.instance;
  late DateTime _weekStart = _mondayOf(DateTime.now());
  /// 이번 주 일정을 한 날로 좁혀 볼 때 (null = 이번 주 전체)
  DateTime? _filterDay;
  bool _showDone = false;
  bool _adding = false;
  final _todoInput = TextEditingController();
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

  void _moveWeek(int delta) => setState(() {
        _weekStart = _weekStart.add(Duration(days: 7 * delta));
        _filterDay = null;
      });

  void _goToday() => setState(() {
        _weekStart = _mondayOf(DateTime.now());
        _filterDay = null;
      });

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

  @override
  void dispose() {
    store.removeListener(_changed);
    RuntimeMode.instance.removeListener(_modeChanged);
    _ticker?.cancel();
    _todoInput.dispose();
    super.dispose();
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------- 일정 ----------

  Future<void> _addSchedule() async {
    final saved = await Navigator.push<Schedule>(
      context,
      MaterialPageRoute(builder: (_) => const ScheduleFormScreen()),
    );
    // "일정 저장하고 경로 준비": 저장하면 바로 이동 탭에서 경로를 보여 줘요
    if (saved != null && mounted) widget.onOpenScheduleRoutes?.call(saved);
  }

  Future<void> _scheduleMenu(Schedule s, String action) async {
    final controller = ScheduleScope.of(context);
    switch (action) {
      case 'detail':
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => DetailScreen(title: s.title, schedule: s, onOpenScheduleRoutes: widget.onOpenScheduleRoutes)));
      case 'edit':
        await Navigator.push<Schedule>(context, MaterialPageRoute(builder: (_) => ScheduleFormScreen(existing: s)));
      case 'delete':
        try {
          await controller.deleteSchedule(s.id);
        } catch (e) {
          _snack('일정 삭제 실패: $e');
        }
    }
  }

  Schedule? _nextSchedule(List<Schedule> all) {
    final upcoming = all.where((s) => !s.isCompleted && s.startTime.isAfter(_now)).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return upcoming.isEmpty ? null : upcoming.first;
  }

  // ---------- 할 일 ----------

  Future<void> _addTodo() async {
    final text = _todoInput.text.trim();
    if (text.isEmpty || _adding) return;
    setState(() => _adding = true);
    try {
      // 장소 종류는 AI가, 머무는 시간은 서버가 장소 종류로 정해요
      final saved = await TodoScope.of(context).addTodo(title: text);
      _todoInput.clear();
      if (saved.placeTypes.isEmpty) {
        _snack('"${saved.title}"에 들를 장소를 찾지 못했어요. 장소 칩을 눌러 골라 주세요.');
      }
    } catch (e) {
      _snack('할 일 저장 실패: $e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _save(TodoItem updated) async {
    try {
      await TodoScope.of(context).updateTodo(updated);
    } catch (e) {
      _snack('할 일 변경 실패: $e');
    }
  }

  Future<void> _deleteTodo(TodoItem todo) async {
    try {
      await TodoScope.of(context).deleteTodo(todo.id);
    } catch (e) {
      _snack('할 일 삭제 실패: $e');
    }
  }

  /// 장소 종류·머무는 시간·꼭 여부를 한 창에서 고쳐요
  Future<void> _editTodo(TodoItem todo) async {
    final result = await showModalBottomSheet<TodoItem>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _TodoEditSheet(todo: todo),
    );
    if (result != null) await _save(result);
  }

  void _openRoutesForTodos() {
    final next = _nextSchedule(ScheduleScope.of(context).schedules);
    if (next == null) {
      _snack('먼저 일정을 추가해 주세요. 일정으로 경로를 받은 뒤 할 일을 적용할 수 있어요.');
      setState(() => _tab = 0);
      return;
    }
    widget.onOpenScheduleRoutes?.call(next);
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            const Text('일정 · 할 일', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            _TabSwitch(
              index: _tab,
              labels: const ['일정', '할 일'],
              icons: const [Icons.event_rounded, Icons.check_box_outlined],
              onChanged: (i) => setState(() => _tab = i),
            ),
            const SizedBox(height: 16),
            if (_tab == 0) ..._scheduleTab() else ..._todoTab(),
          ],
        ),
      ),
    );
  }

  List<Widget> _scheduleTab() {
    final controller = ScheduleScope.of(context);
    final weekEnd = _weekStart.add(const Duration(days: 7));
    final week = controller.schedules
        .where((s) => !s.startTime.isBefore(_weekStart) && s.startTime.isBefore(weekEnd))
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final filterDay = _filterDay;
    final shown = filterDay == null ? week : week.where((s) => _dateOnly(s.startTime) == filterDay).toList();

    final groups = <String, List<Schedule>>{};
    for (final s in shown) {
      groups.putIfAbsent(_dayLabel(s.startTime, _now), () => []).add(s);
    }
    final lastDay = weekEnd.subtract(const Duration(days: 1));

    return [
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
        onPressed: _addSchedule,
        icon: const Icon(Icons.add),
        label: const Text('일정 추가', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      const SizedBox(height: 6),
      const Text('목적지와 도착 시각을 넣으면, 언제 나가야 하는지 거꾸로 계산해 드려요.',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      const SizedBox(height: 16),

      // 주 이동 + 요일 띠 (장우 님 달력)
      Row(children: [
        IconButton(onPressed: () => _moveWeek(-1), icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(
          child: Text(
            '${_weekStart.month}월 ${_weekStart.day}일 – ${lastDay.month}월 ${lastDay.day}일',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
          ),
        ),
        IconButton(onPressed: () => _moveWeek(1), icon: const Icon(Icons.chevron_right_rounded)),
        TextButton(onPressed: _goToday, child: const Text('오늘')),
      ]),
      _WeekStrip(
        weekStart: _weekStart,
        selected: filterDay,
        today: _dateOnly(_now),
        counts: {
          for (var i = 0; i < 7; i++)
            i: week.where((s) => _dateOnly(s.startTime) == _weekStart.add(Duration(days: i))).length,
        },
        onSelect: (d) => setState(() => _filterDay = _filterDay == d ? null : d),
      ),
      const SizedBox(height: 12),

      if (controller.isLoading)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (shown.isEmpty) ...[
        _Empty(icon: Icons.event_available,
            text: filterDay != null ? '이 날은 잡힌 일정이 없어요.' : '이번 주에 잡힌 일정이 없어요.\n위의 "일정 추가"로 가야 할 곳을 넣어 보세요.'),
        if (filterDay != null)
          Center(child: TextButton(onPressed: () => setState(() => _filterDay = null), child: const Text('이번 주 전체 보기'))),
      ] else
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textMuted)),
          ),
          for (final s in entry.value)
            if (!s.isCompleted && s.startTime.isAfter(_now))
              _ScheduleCard(
                schedule: s,
                onRoute: () => widget.onOpenScheduleRoutes?.call(s),
                onMenu: (action) => _scheduleMenu(s, action),
              )
            else
              // 지난 일정은 흐리게, 경로 보기 없이
              Opacity(opacity: 0.55, child: _ScheduleCard(schedule: s, onMenu: (action) => _scheduleMenu(s, action))),
        ],

      // 시간표: 매주 반복 (장우 님 화면 그대로)
      const SizedBox(height: 26),
      _SectionHeader(
        title: '시간표',
        subtitle: '매주 반복되는 일정',
        actionLabel: '반복 추가',
        onAction: () => _editRoutine(null, weekday: _dateOnly(_now).weekday),
      ),
      _Timetable(
        weekStart: _weekStart,
        now: _now,
        routines: store.routines,
        schedules: const [],
        onTapRoutine: (r) => _editRoutine(r),
        onTapSchedule: (s) => widget.onOpenScheduleRoutes?.call(s),
        onTapEmpty: (weekday, minutes) => _editRoutine(null, weekday: weekday, startMinutes: minutes),
      ),
      const SizedBox(height: 6),
      Text(
        '빈 칸을 누르면 그 요일·시간에 반복 일정을 넣고, 블록을 누르면 고쳐요. 이 기기에만 저장돼요.'
        '${RuntimeMode.instance.isDemo ? ' (시연 모드 예시 시간표)' : ''}',
        style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
      ),
    ];
  }

  List<Widget> _todoTab() {
    final controller = TodoScope.of(context);
    final open = controller.todos.where((t) => !t.isCompleted).toList()
      ..sort((a, b) => (b.important ? 1 : 0) - (a.important ? 1 : 0));
    final done = controller.todos.where((t) => t.isCompleted).toList();

    return [
      // ① 추가: 문장 하나만
      _Card(children: [
        const Text('가는 길에 할 일', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('적기만 하면 들를 장소는 AI가 찾아 줘요.',
            style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _todoInput,
              enabled: !_adding,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _addTodo(),
              decoration: const InputDecoration(
                hintText: '예: 이어폰 사기, 택배 부치기',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _adding ? null : _addTodo,
            child: _adding
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('추가'),
          ),
        ]),
        if (_adding)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('AI가 들를 장소를 찾는 중이에요…', style: TextStyle(fontSize: 12, color: AppTheme.primary)),
          ),
      ]),
      const SizedBox(height: 12),

      // ② 등록과 적용은 별개라는 안내 (스케치 그대로)
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('할 일을 등록하는 것과 이번 이동에 넣는 것은 따로예요. '
              '이동 탭에서 경로를 받은 뒤 "할 일 적용하기"로 이번에 들를 곳을 골라요.',
              style: TextStyle(fontSize: 13, color: AppTheme.primary, height: 1.4)),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openRoutesForTodos,
            icon: const Icon(Icons.alt_route, size: 18),
            label: const Text('이동 경로에서 고르기'),
          ),
        ]),
      ),
      const SizedBox(height: 16),

      // ③ 목록
      if (controller.isLoading)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (open.isEmpty)
        const _Empty(icon: Icons.checklist, text: '아직 할 일이 없어요.\n나가는 길에 하고 싶은 일을 적어 보세요.')
      else
        for (final t in open)
          _TodoRow(
            todo: t,
            onToggle: () => _save(t.copyWith(isCompleted: true)),
            onEdit: () => _editTodo(t),
            onStar: () => _save(t.copyWith(important: !t.important)),
            onDelete: () => _deleteTodo(t),
          ),
      if (done.isNotEmpty) ...[
        TextButton.icon(
          onPressed: () => setState(() => _showDone = !_showDone),
          icon: Icon(_showDone ? Icons.expand_less : Icons.expand_more),
          label: Text('완료 ${done.length}개'),
        ),
        if (_showDone)
          for (final t in done)
            _TodoRow(
              todo: t,
              onToggle: () => _save(t.copyWith(isCompleted: false)),
              onEdit: () => _editTodo(t),
              onStar: () => _save(t.copyWith(important: !t.important)),
              onDelete: () => _deleteTodo(t),
            ),
      ],
    ];
  }
}

// ---------- 작은 부품 ----------

class _TabSwitch extends StatelessWidget {
  const _TabSwitch({required this.index, required this.labels, required this.icons, required this.onChanged});
  final int index;
  final List<String> labels;
  final List<IconData> icons;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: i == index ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: i == index
                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6, offset: const Offset(0, 2))]
                      : null,
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icons[i], size: 18, color: i == index ? AppTheme.primary : AppTheme.textMuted),
                  const SizedBox(width: 6),
                  Text(labels[i], style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: i == index ? AppTheme.primary : AppTheme.textMuted,
                  )),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(children: [
          Icon(icon, size: 36, color: AppTheme.textMuted),
          const SizedBox(height: 8),
          Text(text, textAlign: TextAlign.center, style: const TextStyle(color: AppTheme.textMuted, height: 1.5)),
        ]),
      );
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({required this.schedule, required this.onMenu, this.onRoute});
  final Schedule schedule;
  final VoidCallback? onRoute;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final s = schedule;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Text(_hm(s.startTime), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const Text('도착', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        ]),
        Container(width: 3, height: 40, margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(2))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 2),
            Row(children: [
              const Icon(Icons.place_outlined, size: 14, color: AppTheme.textMuted),
              const SizedBox(width: 2),
              Expanded(
                child: Text(s.location, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
              ),
            ]),
          ]),
        ),
        if (onRoute != null)
          FilledButton.tonal(
            onPressed: onRoute,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12)),
            child: const Text('경로 보기'),
          ),
        PopupMenuButton<String>(
          onSelected: onMenu,
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'detail', child: Text('상세 보기')),
            PopupMenuItem(value: 'edit', child: Text('수정')),
            PopupMenuItem(value: 'delete', child: Text('삭제', style: TextStyle(color: AppTheme.danger))),
          ],
        ),
      ]),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({
    required this.todo,
    required this.onToggle,
    required this.onEdit,
    required this.onStar,
    required this.onDelete,
  });
  final TodoItem todo;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final VoidCallback onStar;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = todo;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.important && !t.isCompleted ? AppTheme.primary : AppTheme.border),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tooltip(
          message: t.isCompleted ? '완료 취소' : '완료',
          child: Checkbox(value: t.isCompleted, onChanged: (_) => onToggle()),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, style: TextStyle(
                fontWeight: FontWeight.w700,
                decoration: t.isCompleted ? TextDecoration.lineThrough : null,
                color: t.isCompleted ? AppTheme.textMuted : AppTheme.textStrong,
              )),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                if (t.placeTypes.isEmpty)
                  ActionChip(
                    avatar: const Icon(Icons.add_location_alt_outlined, size: 16, color: AppTheme.warn),
                    label: const Text('장소 고르기'),
                    labelStyle: const TextStyle(color: AppTheme.warn, fontSize: 12),
                    backgroundColor: AppTheme.warnSoft,
                    side: BorderSide.none,
                    onPressed: onEdit,
                  )
                else
                  for (final p in t.placeTypes)
                    ActionChip(
                      label: Text(p),
                      labelStyle: const TextStyle(color: AppTheme.primary, fontSize: 12, fontWeight: FontWeight.w600),
                      backgroundColor: AppTheme.primarySoft,
                      side: BorderSide.none,
                      onPressed: onEdit,
                    ),
                ActionChip(
                  avatar: const Icon(Icons.timer_outlined, size: 16),
                  label: Text('약 ${t.estimatedMinutes}분 머물기'),
                  labelStyle: const TextStyle(fontSize: 12),
                  backgroundColor: AppTheme.background,
                  side: BorderSide.none,
                  onPressed: onEdit,
                ),
              ]),
            ]),
          ),
        ),
        IconButton(
          tooltip: t.important ? '꼭 해야 해요 (끄기)' : '꼭 해야 해요',
          onPressed: onStar,
          icon: Icon(t.important ? Icons.star_rounded : Icons.star_outline_rounded,
              color: t.important ? AppTheme.primary : AppTheme.textMuted),
        ),
        PopupMenuButton<String>(
          onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('장소·시간 바꾸기')),
            PopupMenuItem(value: 'delete', child: Text('삭제', style: TextStyle(color: AppTheme.danger))),
          ],
        ),
      ]),
    );
  }
}

/// 할 일의 장소 종류(여러 개), 머무는 시간, 꼭 여부를 고치는 창
class _TodoEditSheet extends StatefulWidget {
  const _TodoEditSheet({required this.todo});
  final TodoItem todo;

  @override
  State<_TodoEditSheet> createState() => _TodoEditSheetState();
}

class _TodoEditSheetState extends State<_TodoEditSheet> {
  late final Set<String> _types = {...widget.todo.placeTypes};
  late int _minutes = widget.todo.estimatedMinutes > 0 ? widget.todo.estimatedMinutes : 5;
  late bool _important = widget.todo.important;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.todo.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 16),
          const Text('어디에 들르면 돼요?', style: TextStyle(fontWeight: FontWeight.w700)),
          const Text('여러 개를 고르면 그중 가까운 곳을 찾아요.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final p in kPlaceTypes)
              FilterChip(
                label: Text(p),
                selected: _types.contains(p),
                onSelected: (on) => setState(() => on ? _types.add(p) : _types.remove(p)),
              ),
          ]),
          const SizedBox(height: 18),
          const Text('얼마나 머물러요?', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Row(children: [
            IconButton.outlined(
              onPressed: _minutes > 1 ? () => setState(() => _minutes = (_minutes - 1).clamp(1, 120)) : null,
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 80,
              child: Text('$_minutes분', textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ),
            IconButton.outlined(
              onPressed: _minutes < 120 ? () => setState(() => _minutes = (_minutes + 1).clamp(1, 120)) : null,
              icon: const Icon(Icons.add),
            ),
          ]),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _important,
            onChanged: (v) => setState(() => _important = v),
            title: const Text('꼭 해야 해요', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('시간이 부족해도 빼지 않고 "이번엔 빼기 / 늦더라도 들르기"로 물어봐요.'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(context, widget.todo.copyWith(
              placeTypes: [for (final p in kPlaceTypes) if (_types.contains(p)) p],
              requiresTravel: _types.isNotEmpty,
              estimatedMinutes: _minutes,
              important: _important,
            )),
            child: const Text('저장'),
          ),
        ]),
      ),
    );
  }
}

// ======================================================================
// 아래는 장우 님 코드 그대로 (요일 띠, 시간표, 반복 일정 창)
// ======================================================================

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
