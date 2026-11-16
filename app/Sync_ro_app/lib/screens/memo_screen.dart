import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/memo.dart';
import '../models/schedule.dart';
import '../services/home_widget_bridge.dart';
import '../services/memo_storage_service.dart';
import '../services/memo_promotion_parser.dart';
import '../services/place_recommendation_service.dart';
import 'schedule_form_screen.dart';
import 'todo_screen.dart';

/// 홈 화면 위젯과 같은 메모를 보고 고치는 화면.
/// 위젯은 '할일 / 일정' 분류와 완료 여부만 다루고, 자세한 정리는 여기서 해요.
class MemoScreen extends StatefulWidget {
  const MemoScreen({super.key, this.onPromoted});

  /// 메모를 기존 할일/일정 데이터로 옮긴 뒤 해당 플래너 탭을 열어 달라는 신호.
  final ValueChanged<MemoType>? onPromoted;

  @override
  MemoScreenState createState() => MemoScreenState();
}

class MemoScreenState extends State<MemoScreen> with WidgetsBindingObserver {
  final MemoStorageService _storage = MemoStorageService();

  List<Memo> _memos = const [];
  MemoType? _filter;
  bool _loading = true;
  int _loadToken = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    MemoStorageService.revision.addListener(_reloadFromRevision);
    reload();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MemoStorageService.revision.removeListener(_reloadFromRevision);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 위젯에서 메모를 고친 뒤 앱으로 돌아오면 바로 다시 읽어요.
    if (state == AppLifecycleState.resumed) reload();
  }

  void _reloadFromRevision() => reload();

  Future<void> reload() async {
    final token = ++_loadToken;
    final memos = await _storage.load();
    if (!mounted || token != _loadToken) return;
    setState(() {
      _memos = memos;
      _loading = false;
    });
  }

  List<Memo> get _visible => _filter == null
      ? _memos
      : _memos.where((memo) => memo.type == _filter).toList();

  int get _todoCount =>
      _memos.where((memo) => memo.type == MemoType.todo).length;

  int get _scheduleCount =>
      _memos.where((memo) => memo.type == MemoType.schedule).length;

  Future<void> _openEditor({Memo? existing}) async {
    final draft = await showDialog<_MemoDraft>(
      context: context,
      builder: (_) => _MemoDialog(existing: existing),
    );
    if (draft == null) return;

    // 위젯에서 먼저 고친 내용을 덮어쓰지 않도록 저장 직전에 다시 읽어요.
    final memos = List<Memo>.of(await _storage.load());
    if (!mounted) return;
    if (existing == null) {
      final now = DateTime.now();
      var id = now.millisecondsSinceEpoch;
      for (final memo in memos) {
        if (memo.id >= id) id = memo.id + 1;
      }
      memos.add(
        Memo(id: id, text: draft.text, type: draft.type, createdAt: now),
      );
    } else {
      final index = memos.indexWhere((memo) => memo.id == existing.id);
      if (index < 0) return;
      memos[index] = memos[index].copyWith(text: draft.text, type: draft.type);
    }
    await _storage.save(memos);
    await reload();
  }

  Future<void> _toggle(Memo memo) async {
    final memos = List<Memo>.of(await _storage.load());
    if (!mounted) return;
    final index = memos.indexWhere((item) => item.id == memo.id);
    if (index < 0) return;
    final latest = memos[index];
    memos[index] = latest.copyWith(done: !latest.done);
    await _storage.save(memos);
    await reload();
  }

  Future<void> _delete(Memo memo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('메모 삭제'),
        content: Text('"${memo.text}" 메모를 지울까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final memos = List<Memo>.of(await _storage.load());
    if (!mounted) return;
    await _storage.save(memos.where((item) => item.id != memo.id).toList());
    await reload();
  }

  /// 메모의 분류에 따라 기존 할일/일정 추가 폼을 열어요.
  Future<void> _promote(Memo memo) async {
    if (memo.type == MemoType.schedule) {
      await _promoteSchedule(memo);
    } else {
      await _promoteTodo(memo);
    }
  }

  Future<void> _promoteTodo(Memo memo) async {
    final recommendations = const PlaceRecommendationService().recommend(
      memo.text,
    );
    final first = recommendations.isEmpty ? null : recommendations.first;
    final saved = await TodoScreen.showTodoDialog(
      context,
      initialTitle: memo.text,
      initialPlaceType:
          first?.category ?? MemoPromotionParser.todoPlaceType(memo.text),
      initialPlaceName: first?.name,
    );
    if (saved == null || !mounted) return;

    await _removePromotedMemo(memo);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('"${memo.text}"을(를) 할 일 탭에 추가했어요.')));
    widget.onPromoted?.call(MemoType.todo);
  }

  Future<void> _promoteSchedule(Memo memo) async {
    final draft = MemoPromotionParser.forSchedule(memo.text);
    final saved = await Navigator.of(context).push<Schedule>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          initial: Schedule(
            id: 0,
            title: draft.title,
            location: draft.location,
            startTime: draft.start,
            endTime: draft.start.add(const Duration(hours: 1)),
          ),
          startRepeating: draft.repeatWeekly,
        ),
      ),
    );
    if (saved == null || !mounted) return;

    await _removePromotedMemo(memo);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          draft.repeatWeekly
              ? '"${memo.text}"을(를) 매주 반복 일정으로 시간표에 추가했어요.'
              : '"${memo.text}"을(를) 일정 탭에 추가했어요.',
        ),
      ),
    );
    widget.onPromoted?.call(MemoType.schedule);
  }

  /// 기존 데이터로 등록된 메모는 메모 목록에서 빼서 중복 등록을 막아요.
  Future<void> _removePromotedMemo(Memo memo) async {
    final memos = List<Memo>.of(await _storage.load());
    if (!mounted) return;
    await _storage.save(memos.where((item) => item.id != memo.id).toList());
    await reload();
  }

  Future<void> _pinWidget() async {
    final requested = await HomeWidgetBridge.requestPinWidget();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          requested
              ? '확인 창에서 "추가"를 누르면 홈 화면에 메모 위젯이 생겨요.'
              : '홈 화면을 길게 눌러 위젯 목록에서 "메모"를 골라 주세요.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('메모'),
        actions: [
          IconButton(
            onPressed: _pinWidget,
            tooltip: '홈 화면 위젯 추가',
            icon: const Icon(Icons.widgets_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.edit_note),
        label: const Text('메모 추가'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                children: [
                  _buildWidgetGuide(),
                  const SizedBox(height: 14),
                  _buildFilters(),
                  const SizedBox(height: 6),
                  if (_visible.isEmpty)
                    _buildEmpty()
                  else
                    ..._visible.map(_buildMemoTile),
                ],
              ),
            ),
    );
  }

  Widget _buildWidgetGuide() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primarySoft,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.widgets_outlined,
                size: 20,
                color: AppTheme.primary,
              ),
              const SizedBox(width: 8),
              const Text(
                '홈 화면 메모 위젯',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textStrong,
                ),
              ),
              const Spacer(),
              TextButton(onPressed: _pinWidget, child: const Text('위젯 추가')),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '메모는 여기에 보관돼요. 오른쪽 "할일로" 또는 "일정으로" 버튼을 누르면 '
            '기존 추가 폼이 열리고, 장소·시간을 확인한 뒤 할 일·일정 탭에 등록할 수 있어요. '
            '위젯 하단 입력줄에 적은 내용도 AI가 분류해 메모에 저장합니다.',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          label: Text('전체 ${_memos.length}'),
          selected: _filter == null,
          onSelected: (_) => setState(() => _filter = null),
        ),
        ChoiceChip(
          label: Text('할일 $_todoCount'),
          selected: _filter == MemoType.todo,
          onSelected: (_) => setState(() => _filter = MemoType.todo),
        ),
        ChoiceChip(
          label: Text('일정 $_scheduleCount'),
          selected: _filter == MemoType.schedule,
          onSelected: (_) => setState(() => _filter = MemoType.schedule),
        ),
      ],
    );
  }

  Widget _buildEmpty() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.sticky_note_2_outlined,
            size: 44,
            color: AppTheme.textMuted.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 12),
          Text(
            _filter == null
                ? '아직 메모가 없어요.\n아래 "메모 추가"로 첫 메모를 남겨 보세요.'
                : '이 분류에 해당하는 메모가 없어요.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 13,
              height: 1.5,
              color: AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoTile(Memo memo) {
    final done = memo.done;
    final recommendations = memo.type == MemoType.todo
        ? const PlaceRecommendationService().recommend(memo.text, limit: 2)
        : const [];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: ListTile(
        leading: Checkbox(
          value: done,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          onChanged: (_) => _toggle(memo),
        ),
        title: Text(
          memo.text,
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w600,
            color: done ? AppTheme.textMuted : AppTheme.textStrong,
            decoration: done ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _typeTag(memo.type),
                  const SizedBox(width: 8),
                  Text(
                    _dateLabel(memo.createdAt),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
              if (recommendations.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '추천: ${recommendations.map((item) => item.name).join(' · ')}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (recommendations.isEmpty &&
                  memo.type == MemoType.todo &&
                  PlaceRecommendationService.looksLikePurchase(memo.text))
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    '추천: 할일로를 누르면 AI가 주변 매장을 찾아요',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                  ),
                ),
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: '추가 정보를 입력하고 ${memo.type.label} 탭으로 이동',
              child: TextButton(
                onPressed: () => _promote(memo),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  memo.type == MemoType.schedule ? '일정으로' : '할일로',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  _openEditor(existing: memo);
                } else if (value == 'delete') {
                  _delete(memo);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('수정')),
                PopupMenuItem(value: 'delete', child: Text('삭제')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeTag(MemoType type) {
    final isTodo = type == MemoType.todo;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: isTodo ? AppTheme.warnSoft : AppTheme.primarySoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        type.label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: isTodo ? AppTheme.warn : AppTheme.primary,
        ),
      ),
    );
  }

  String _dateLabel(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    if (now.year == time.year &&
        now.month == time.month &&
        now.day == time.day) {
      return '오늘 $hh:$mm';
    }
    return '${time.month}월 ${time.day}일 $hh:$mm';
  }
}

class _MemoDraft {
  const _MemoDraft(this.text, this.type);

  final String text;
  final MemoType type;
}

class _MemoDialog extends StatefulWidget {
  const _MemoDialog({this.existing});

  final Memo? existing;

  @override
  State<_MemoDialog> createState() => _MemoDialogState();
}

class _MemoDialogState extends State<_MemoDialog> {
  late final TextEditingController _controller;
  late MemoType _type;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.existing?.text ?? '');
    _type = widget.existing?.type ?? MemoType.todo;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(_MemoDraft(text, _type));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '메모 추가' : '메모 수정'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 2,
            maxLines: 4,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(hintText: '무엇을 기억할까요?'),
          ),
          const SizedBox(height: 14),
          SegmentedButton<MemoType>(
            segments: const [
              ButtonSegment(
                value: MemoType.todo,
                label: Text('할일'),
                icon: Icon(Icons.check_circle_outline, size: 18),
              ),
              ButtonSegment(
                value: MemoType.schedule,
                label: Text('일정'),
                icon: Icon(Icons.event_outlined, size: 18),
              ),
            ],
            selected: {_type},
            onSelectionChanged: (selection) =>
                setState(() => _type = selection.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _submit, child: const Text('저장')),
      ],
    );
  }
}
