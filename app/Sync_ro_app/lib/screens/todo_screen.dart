import 'package:flutter/material.dart';

import '../models/todo_item.dart';
import '../providers/todo_controller.dart';

class TodoScreen extends StatelessWidget {
  const TodoScreen({super.key});

  Future<void> _showTodoDialog(BuildContext context, {TodoItem? existing}) async {
    // Obtain the notifier before opening the dialog. Do not depend on a
    // dialog's BuildContext after it has been removed from the tree.
    final todoController = TodoScope.of(context);
    final result = await showDialog<_TodoFormResult>(
      context: context,
      builder: (_) => _TodoFormDialog(existing: existing),
    );
    if (result == null) return;

    if (existing == null) {
      await todoController.addTodo(
        title: result.title,
        minutes: result.minutes,
        requiresTravel: false, // Future NLP pipeline will infer travel needs.
      );
    } else {
      await todoController.updateTodo(existing.copyWith(
        title: result.title,
        estimatedMinutes: result.minutes,
      ));
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
                                  onChanged: (_) => controller.toggleCompleted(todo),
                                ),
                                title: Text(todo.title,
                                    style: TextStyle(
                                      decoration: todo.isCompleted
                                          ? TextDecoration.lineThrough
                                          : null,
                                    )),
                                subtitle: Text('예상 ${todo.estimatedMinutes}분'),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'edit') {
                                      _showTodoDialog(context, existing: todo);
                                    } else if (value == 'delete') {
                                      controller.deleteTodo(todo.id);
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

  const _TodoFormResult(this.title, this.minutes);
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
            ));
          },
          child: const Text('저장'),
        ),
      ],
    );
  }
}
