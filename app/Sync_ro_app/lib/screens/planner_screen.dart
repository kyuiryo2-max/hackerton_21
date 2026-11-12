import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../providers/schedule_controller.dart';
import '../providers/todo_controller.dart';
import 'detail_screen.dart';
import 'schedule_form_screen.dart';

/// 할 일·일정 탭 (11/13 개편, 규리 님 스케치)
///
/// [일정 | 할 일] 두 탭으로 나눠요.
/// - 일정: 정해진 시각까지 가야 하는 곳. 장소 + 도착 목표 시각. "경로 보기"로 이동 탭에 이어져요.
/// - 할 일: 가는 길에 해치울 일. 문장 하나만 쓰면 AI가 장소 종류를 붙이고, 머무는 시간은 장소별 기본값.
///   시간·요일·반복은 없어요. 이번 이동에 넣는 건 이동 탭의 "할 일 적용하기"에서 골라요.
///
/// 예전의 주간 시간표(매주 반복, 기기에만 저장)는 경로 추천에 안 쓰여서 사용 테스트 동안 뺐어요.
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

String _two(int v) => v.toString().padLeft(2, '0');
String _hm(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';
DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

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
  bool _showPast = false;
  bool _showDone = false;
  bool _adding = false;
  final _todoInput = TextEditingController();
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
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
    final all = controller.schedules.toList()..sort((a, b) => a.startTime.compareTo(b.startTime));
    final upcoming = all.where((s) => !s.isCompleted && s.startTime.isAfter(_now)).toList();
    final past = all.where((s) => !upcoming.contains(s)).toList().reversed.toList();

    final groups = <String, List<Schedule>>{};
    for (final s in upcoming) {
      groups.putIfAbsent(_dayLabel(s.startTime, _now), () => []).add(s);
    }

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
      if (controller.isLoading)
        const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
      else if (upcoming.isEmpty)
        const _Empty(icon: Icons.event_available, text: '다가오는 일정이 없어요.\n위의 "일정 추가"로 가야 할 곳을 넣어 보세요.')
      else
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(entry.key, style: const TextStyle(fontWeight: FontWeight.w800, color: AppTheme.textMuted)),
          ),
          for (final s in entry.value)
            _ScheduleCard(
              schedule: s,
              onRoute: () => widget.onOpenScheduleRoutes?.call(s),
              onMenu: (action) => _scheduleMenu(s, action),
            ),
        ],
      if (past.isNotEmpty) ...[
        TextButton.icon(
          onPressed: () => setState(() => _showPast = !_showPast),
          icon: Icon(_showPast ? Icons.expand_less : Icons.expand_more),
          label: Text('지난 일정 ${past.length}개'),
        ),
        if (_showPast)
          for (final s in past)
            Opacity(
              opacity: 0.55,
              child: _ScheduleCard(schedule: s, onMenu: (action) => _scheduleMenu(s, action)),
            ),
      ],
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
