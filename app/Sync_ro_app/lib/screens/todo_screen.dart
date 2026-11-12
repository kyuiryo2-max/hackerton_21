import 'package:flutter/material.dart';

import '../models/todo_item.dart';
import '../providers/todo_controller.dart';

class TodoScreen extends StatelessWidget {
  const TodoScreen({super.key});

  Future<void> _showTodoDialog(BuildContext context, {TodoItem? existing}) =>
      showTodoDialog(context, existing: existing);

  /// 할 일 추가·수정 창. 저장된 할 일을 돌려주고, 취소·실패면 null.
  /// (할 일·일정 탭에서도 같은 창을 써요)
  static Future<TodoItem?> showTodoDialog(BuildContext context, {TodoItem? existing}) async {
    // Obtain the notifier before opening the dialog. Do not depend on a
    // dialog's BuildContext after it has been removed from the tree.
    final todoController = TodoScope.of(context);
    final result = await showDialog<_TodoFormResult>(
      context: context,
      builder: (_) => _TodoFormDialog(existing: existing),
    );
    if (result == null) return null;

    try {
      if (existing == null) {
        return await todoController.addTodo(
          title: result.title,
          minutes: result.minutes,
          requiresTravel: result.placeType != null,
          placeType: result.placeType,
        );
      }
      final updated = existing.copyWith(
        title: result.title,
        estimatedMinutes: result.minutes,
      );
      await todoController.updateTodo(updated, placeType: result.placeType);
      return updated;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('할 일 서버 저장 실패: $error')));
      }
      return null;
    }
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
                    child: Text(controller.error!,
                        style: const TextStyle(color: Colors.red)),
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
                                  horizontal: 12, vertical: 5),
                              child: ListTile(
                                leading: Checkbox(
                                  value: todo.isCompleted,
                                  onChanged: (_) async {
                                    try {
                                      await controller.toggleCompleted(todo);
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(content: Text('할 일 변경 실패: $e')));
                                      }
                                    }
                                  },
                                ),
                                title: Text(todo.title,
                                    style: TextStyle(
                                      decoration: todo.isCompleted
                                          ? TextDecoration.lineThrough
                                          : null,
                                    )),
                                subtitle: Text(
                                  '예상 ${todo.estimatedMinutes}분 · '
                                  '${todo.isCompleted ? '완료' : (todo.requiresTravel ? '경유지 추천 후보' : '경유 장소 미분류 · 수정에서 장소 종류 선택')}',
                                ),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (value) async {
                                    if (value == 'edit') {
                                      await _showTodoDialog(context, existing: todo);
                                    } else if (value == 'delete') {
                                      try {
                                        await controller.deleteTodo(todo.id);
                                      } catch (e) {
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('할 일 삭제 실패: $e')));
                                        }
                                      }
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(value: 'edit', child: Text('수정')),
                                    PopupMenuItem(value: 'delete', child: Text('삭제')),
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
  const _TodoFormResult(this.title, this.minutes, this.placeType);
}

// Controllers belong to the dialog's State and are disposed only when Flutter
// unmounts this dialog, not immediately after Navigator.pop is requested.
class _TodoFormDialog extends StatefulWidget {
  final TodoItem? existing;
  const _TodoFormDialog({this.existing});

  @override
  State<_TodoFormDialog> createState() => _TodoFormDialogState();
}

class _TodoFormDialogState extends State<_TodoFormDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _minutesController;
  String _placeType = '';
  static const _placeTypes = <String>[
    '약국', '편의점', '우체국', '꽃집', '케이크집', '카페', '프린트',
    '은행·ATM', '마트', '병원', '안경점', '다이소', '음식점', '빵집', '올리브영',
  ];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.existing?.title ?? '');
    _minutesController = TextEditingController(
        text: '${widget.existing?.estimatedMinutes ?? 15}');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                validator: (value) => value == null || value.trim().isEmpty
                    ? '할 일을 입력해 주세요.'
                    : null,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _placeType,
                decoration: const InputDecoration(labelText: '경유 장소 종류',
                  helperText: '자동 분류가 안 되는 할 일은 직접 선택하세요.'),
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
            Navigator.of(context).pop(_TodoFormResult(
              _titleController.text.trim(),
              int.parse(_minutesController.text.trim()),
              _placeType.isEmpty ? null : _placeType,
            ));
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}
