
import 'package:flutter/material.dart';

import '../models/todo_item.dart';
import '../providers/todo_controller.dart';

class TodoScreen extends StatelessWidget {
  const TodoScreen({super.key});

  Future<void> _showTodoDialog(
    BuildContext context, {
    TodoItem? existing,
  }) async {
    final titleController = TextEditingController(
      text: existing?.title ?? '',
    );

    final minutesController = TextEditingController(
      text: '${existing?.estimatedMinutes ?? 15}',
    );

    bool requiresTravel =
        existing?.requiresTravel ?? false;

    final formKey = GlobalKey<FormState>();

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                title: Text(
                  existing == null ? '할 일 추가' : '할 일 수정',
                ),
                content: Form(
                  key: formKey,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: titleController,
                          decoration: const InputDecoration(
                            labelText: '할 일 이름',
                          ),
                          validator: (value) =>
                              value == null ||
                                      value.trim().isEmpty
                                  ? '이름을 입력해 주세요.'
                                  : null,
                        ),
                        TextFormField(
                          controller: minutesController,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: '예상 소요 시간(분)',
                          ),
                          validator: (value) {
                            final minutes =
                                int.tryParse(value ?? '');

                            if (minutes == null ||
                                minutes <= 0) {
                              return '1분 이상 입력해 주세요.';
                            }
                            return null;
                          },
                        ),
                        SwitchListTile(
                          title: const Text('장소 이동 필요'),
                          value: requiresTravel,
                          onChanged: (value) {
                            setDialogState(() {
                              requiresTravel = value;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(dialogContext),
                    child: const Text('취소'),
                  ),
                  FilledButton(
                    onPressed: () {
                      if (!formKey.currentState!.validate()) {
                        return;
                      }

                      final controller =
                          TodoScope.of(context);

                      final title =
                          titleController.text.trim();

                      final minutes = int.parse(
                        minutesController.text,
                      );

                      if (existing == null) {
                        controller.addTodo(
                          title: title,
                          minutes: minutes,
                          requiresTravel: requiresTravel,
                        );
                      } else {
                        controller.updateTodo(
                          existing.copyWith(
                            title: title,
                            estimatedMinutes: minutes,
                            requiresTravel: requiresTravel,
                          ),
                        );
                      }

                      Navigator.pop(dialogContext);
                    },
                    child: const Text('저장'),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      titleController.dispose();
      minutesController.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = TodoScope.of(context);
    final todos = controller.todos;

    return Scaffold(
      appBar: AppBar(
        title: const Text('내 할 일'),
      ),
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
                      style: const TextStyle(
                        color: Colors.red,
                      ),
                    ),
                  ),
                Expanded(
                  child: todos.isEmpty
                      ? const Center(
                          child: Text('등록된 할 일이 없습니다.'),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(
                            bottom: 100,
                          ),
                          itemCount: todos.length,
                          itemBuilder: (context, index) {
                            final todo = todos[index];

                            return Card(
                              margin:
                                  const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              child: ListTile(
                                leading: Checkbox(
                                  value: todo.isCompleted,
                                  onChanged: (_) {
                                    controller
                                        .toggleCompleted(todo);
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
                                subtitle: Text(
                                  '${todo.estimatedMinutes}분 · '
                                  '${todo.requiresTravel ? "장소 이동 필요" : "현재 위치에서 가능"}',
                                ),
                                trailing: PopupMenuButton<String>(
                                  onSelected: (value) {
                                    if (value == 'edit') {
                                      _showTodoDialog(
                                        context,
                                        existing: todo,
                                      );
                                    } else if (value ==
                                        'delete') {
                                      controller.deleteTodo(
                                        todo.id,
                                      );
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
