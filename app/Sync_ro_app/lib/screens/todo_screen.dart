import 'dart:async';

import 'package:flutter/material.dart';

import '../models/place_recommendation.dart';
import '../models/todo_item.dart';
import '../providers/todo_controller.dart';
import '../services/ai_place_recommendation_service.dart';
import '../services/location_access.dart';
import '../services/place_recommendation_service.dart';

class TodoScreen extends StatelessWidget {
  const TodoScreen({super.key});

  Future<void> _showTodoDialog(BuildContext context, {TodoItem? existing}) =>
      showTodoDialog(context, existing: existing);

  /// 할 일 추가·수정 창. 저장된 할 일을 돌려주고, 취소·실패면 null.
  /// (할 일·일정 탭에서도 같은 창을 써요)
  static Future<TodoItem?> showTodoDialog(
    BuildContext context, {
    TodoItem? existing,
    String? initialTitle,
    String? initialPlaceType,
    String? initialPlaceName,
  }) async {
    // Obtain the notifier before opening the dialog. Do not depend on a
    // dialog's BuildContext after it has been removed from the tree.
    final todoController = TodoScope.of(context);
    final result = await showDialog<_TodoFormResult>(
      context: context,
      builder: (_) => _TodoFormDialog(
        existing: existing,
        initialTitle: initialTitle,
        initialPlaceType: initialPlaceType,
        initialPlaceName: initialPlaceName,
      ),
    );
    if (result == null) return null;

    try {
      if (existing == null) {
        return await todoController.addTodo(
          title: result.title,
          minutes: result.minutes,
          requiresTravel: result.placeType != null || result.placeName != null,
          placeName: result.placeName,
          placeType: result.placeType,
        );
      }
      final updated = existing.copyWith(
        title: result.title,
        estimatedMinutes: result.minutes,
        placeName: result.placeName ?? '',
      );
      await todoController.updateTodo(updated, placeType: result.placeType);
      return updated;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('할 일 서버 저장 실패: $error')));
      }
      return null;
    }
  }

  String _todoSubtitle(TodoItem todo) {
    final place = todo.placeName?.trim();
    if (place != null && place.isNotEmpty) {
      return '예상 ${todo.estimatedMinutes}분 · $place';
    }
    final hasStopover = todo.requiresTravel || todo.hasStopover;
    return '예상 ${todo.estimatedMinutes}분 · '
        '${todo.isCompleted ? '완료' : (hasStopover ? '경유지 추천 후보' : '경유 장소 미분류 · 수정에서 장소 종류 선택')}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = TodoScope.of(context);
    final todos = controller.todos;

    return Scaffold(
      appBar: AppBar(title: const Text('내 할 일')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showTodoDialog(context),
        icon: const Icon(Icons.add),
        label: const Text('할 일 추가'),
      ),
      body: controller.isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (controller.error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      controller.error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                Expanded(
                  child: todos.isEmpty
                      ? const Center(child: Text('등록된 할 일이 없습니다.'))
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 100),
                          itemCount: todos.length,
                          itemBuilder: (context, index) {
                            final todo = todos[index];
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              child: ListTile(
                                leading: Checkbox(
                                  value: todo.isCompleted,
                                  onChanged: (_) async {
                                    try {
                                      await controller.toggleCompleted(todo);
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text('할 일 변경 실패: $e'),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                ),
                                title: Text(
                                  todo.title,
                                  style: TextStyle(
                                    decoration: todo.isCompleted
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                subtitle: Text(_todoSubtitle(todo)),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (value) async {
                                    if (value == 'edit') {
                                      await _showTodoDialog(
                                        context,
                                        existing: todo,
                                      );
                                    } else if (value == 'delete') {
                                      try {
                                        await controller.deleteTodo(todo.id);
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text('할 일 삭제 실패: $e'),
                                            ),
                                          );
                                        }
                                      }
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: 'edit',
                                      child: Text('수정'),
                                    ),
                                    PopupMenuItem(
                                      value: 'delete',
                                      child: Text('삭제'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

class _TodoFormResult {
  final String title;
  final int minutes;

  final String? placeType;
  final String? placeName;

  const _TodoFormResult({
    required this.title,
    required this.minutes,
    this.placeType,
    this.placeName,
  });
}

// Controllers belong to the dialog's State and are disposed only when Flutter
// unmounts this dialog, not immediately after Navigator.pop is requested.
class _TodoFormDialog extends StatefulWidget {
  final TodoItem? existing;
  final String? initialTitle;
  final String? initialPlaceType;
  final String? initialPlaceName;

  const _TodoFormDialog({
    this.existing,
    this.initialTitle,
    this.initialPlaceType,
    this.initialPlaceName,
  });

  @override
  State<_TodoFormDialog> createState() => _TodoFormDialogState();
}

class _TodoFormDialogState extends State<_TodoFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _minutesController;
  late final TextEditingController _placeNameController;
  List<PlaceRecommendation> _recommendations = const [];
  List<PlaceRecommendation> _aiRecommendations = const [];
  Timer? _aiDebounce;
  bool _aiLoading = false;
  String? _aiError;
  int _aiRequestId = 0;
  String _placeType = '';
  static const _placeTypes = <String>[
    '약국',
    '편의점',
    '우체국',
    '꽃집',
    '케이크집',
    '카페',
    '프린트',
    '은행·ATM',
    '마트',
    '병원',
    '안경점',
    '다이소',
    '음식점',
    '빵집',
    '올리브영',
    '문구점',
  ];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.existing?.title ?? widget.initialTitle ?? '',
    );
    _minutesController = TextEditingController(
      text: '${widget.existing?.estimatedMinutes ?? 15}',
    );
    _placeNameController = TextEditingController(
      text: widget.existing?.placeName ?? widget.initialPlaceName ?? '',
    );
    _placeType = widget.initialPlaceType ?? '';
    _recommendations = const PlaceRecommendationService().recommend(
      _titleController.text,
    );
    if (_recommendations.isEmpty &&
        PlaceRecommendationService.looksLikePurchase(_titleController.text)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadAiRecommendations();
      });
    }
  }

  @override
  void dispose() {
    _aiDebounce?.cancel();
    _aiRequestId++;
    _titleController.dispose();
    _minutesController.dispose();
    _placeNameController.dispose();
    super.dispose();
  }

  void _refreshRecommendations() {
    final next = const PlaceRecommendationService().recommend(
      _titleController.text,
    );
    _aiDebounce?.cancel();
    _aiRequestId++;
    setState(() {
      _recommendations = next;
      _aiRecommendations = const [];
      _aiLoading = false;
      _aiError = null;
    });
    if (next.isEmpty &&
        PlaceRecommendationService.looksLikePurchase(_titleController.text)) {
      _aiDebounce = Timer(const Duration(milliseconds: 650), () {
        if (mounted) _loadAiRecommendations();
      });
    }
  }

  Future<void> _loadAiRecommendations() async {
    if (_aiLoading) return;
    final text = _titleController.text.trim();
    if (text.isEmpty || _recommendations.isNotEmpty) return;

    final requestId = ++_aiRequestId;
    setState(() {
      _aiLoading = true;
      _aiError = null;
      _aiRecommendations = const [];
    });
    try {
      final position = await LocationAccess.current();
      if (!mounted ||
          requestId != _aiRequestId ||
          _titleController.text.trim() != text) {
        return;
      }
      final places = await const AiPlaceRecommendationService().recommend(
        text: text,
        latitude: position.latitude,
        longitude: position.longitude,
      );
      if (!mounted ||
          requestId != _aiRequestId ||
          _titleController.text.trim() != text) {
        return;
      }
      setState(() {
        _aiLoading = false;
        _aiRecommendations = places;
        _aiError = places.isEmpty ? '현재 위치 주변에서 판매처를 찾지 못했어요.' : null;
      });
    } on LocationAccessException catch (e) {
      if (!mounted || requestId != _aiRequestId) return;
      setState(() {
        _aiLoading = false;
        _aiError = '${e.message}. 위치를 켜면 AI가 주변 매장을 찾을 수 있어요.';
      });
    } on AiPlaceRecommendationException catch (e) {
      if (!mounted || requestId != _aiRequestId) return;
      setState(() {
        _aiLoading = false;
        _aiError = e.message;
      });
    } catch (_) {
      if (!mounted || requestId != _aiRequestId) return;
      setState(() {
        _aiLoading = false;
        _aiError = 'AI 추천을 불러오지 못했어요.';
      });
    }
  }

  void _selectRecommendation(PlaceRecommendation recommendation) {
    setState(() {
      _placeNameController.text = recommendation.name;
      if (_placeTypes.contains(recommendation.category)) {
        _placeType = recommendation.category;
      }
    });
  }

  PlaceRecommendation? get _selectedRecommendation {
    final name = _placeNameController.text.trim();
    for (final recommendation in _visibleRecommendations) {
      if (recommendation.name == name) return recommendation;
    }
    return null;
  }

  List<PlaceRecommendation> get _visibleRecommendations => [
    ..._recommendations,
    ..._aiRecommendations,
  ];

  bool get _canOfferAi =>
      _recommendations.isEmpty && _titleController.text.trim().isNotEmpty;

  String _distanceLabel(int meters) =>
      meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)}km' : '${meters}m';

  @override
  Widget build(BuildContext context) {
    final selectedRecommendation = _selectedRecommendation;
    return AlertDialog(
      title: Text(widget.existing == null ? '할 일 추가' : '할 일 수정'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(labelText: '할 일 내용'),
                onChanged: (_) => _refreshRecommendations(),
                validator: (value) => value == null || value.trim().isEmpty
                    ? '할 일을 입력해 주세요.'
                    : null,
              ),
              const SizedBox(height: 10),
              if (_recommendations.isNotEmpty ||
                  _aiRecommendations.isNotEmpty ||
                  _aiLoading ||
                  _aiError != null ||
                  _canOfferAi) ...[
                Row(
                  children: [
                    if (_aiRecommendations.isNotEmpty) ...[
                      const Icon(Icons.auto_awesome, size: 16),
                      const SizedBox(width: 4),
                    ],
                    Text(
                      _aiRecommendations.isNotEmpty ? 'AI 추천 장소' : '추천 장소',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                if (_aiLoading)
                  const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Expanded(child: Text('현재 위치에서 AI가 주변 매장을 찾는 중...')),
                    ],
                  ),
                if (_visibleRecommendations.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final recommendation in _visibleRecommendations)
                          ChoiceChip(
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: Text(
                                recommendation.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            selected:
                                _placeNameController.text.trim() ==
                                recommendation.name,
                            onSelected: (_) =>
                                _selectRecommendation(recommendation),
                            tooltip: recommendation.reason,
                          ),
                      ],
                    ),
                  ),
                if (selectedRecommendation != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedRecommendation.reason,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if ((selectedRecommendation.address
                                    ?.trim()
                                    .isNotEmpty ??
                                false) ||
                            selectedRecommendation.distanceMeters != null)
                          Text(
                            [
                              if (selectedRecommendation.address
                                      ?.trim()
                                      .isNotEmpty ??
                                  false)
                                selectedRecommendation.address!.trim(),
                              if (selectedRecommendation.distanceMeters != null)
                                _distanceLabel(
                                  selectedRecommendation.distanceMeters!,
                                ),
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                if (_aiError != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _aiError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_canOfferAi &&
                    !_aiLoading &&
                    _aiRecommendations.isEmpty &&
                    _aiError == null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _loadAiRecommendations,
                      icon: const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('AI로 주변 매장 찾기'),
                    ),
                  ),
                if (_aiError != null &&
                    !_aiLoading &&
                    _aiRecommendations.isEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _loadAiRecommendations,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('AI로 다시 찾기'),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
              TextFormField(
                controller: _placeNameController,
                decoration: const InputDecoration(
                  labelText: '구매 장소 (선택)',
                  helperText: '추천 장소를 고르거나 직접 입력하세요.',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                key: ValueKey('place-type-$_placeType'),
                initialValue: _placeType,
                decoration: const InputDecoration(
                  labelText: '경유 장소 종류',
                  helperText: '자동 분류가 안 되는 할 일은 직접 선택하세요.',
                ),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: '', child: Text('자동 분류')),
                  for (final type in _placeTypes)
                    DropdownMenuItem(value: type, child: Text(type)),
                ],
                onChanged: (value) => setState(() => _placeType = value ?? ''),
              ),
              TextFormField(
                controller: _minutesController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '예상 소요 시간(분)'),
                validator: (value) {
                  final minutes = int.tryParse(value?.trim() ?? '');
                  return minutes == null || minutes <= 0
                      ? '1분 이상 입력해 주세요.'
                      : null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            Navigator.of(context).pop(
              _TodoFormResult(
                title: _titleController.text.trim(),
                minutes: int.parse(_minutesController.text.trim()),
                placeType: _placeType.isEmpty ? null : _placeType,
                placeName: _placeNameController.text.trim().isEmpty
                    ? null
                    : _placeNameController.text.trim(),
              ),
            );
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}
