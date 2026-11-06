import 'package:flutter/material.dart';

import '../data/mock_todos.dart';
import '../models/todo_item.dart';
import '../services/todo_storage_service.dart';

class TodoController extends ChangeNotifier {
  final TodoStorageService _storage = TodoStorageService();

  List<TodoItem> _todos = [];
  bool _isLoading = true;
  String? _error;

  List<TodoItem> get todos => List.unmodifiable(_todos);

  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> initialize() async {
    try {
      final saved = await _storage.loadTodos();
      _todos = saved ?? List.of(mockTodos);
      _error = null;
    } catch (e) {
      _error = '할 일 불러오기 실패: $e';
      _todos = List.of(mockTodos);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _persist() async {
    notifyListeners();

    try {
      await _storage.saveTodos(_todos);
      _error = null;
    } catch (e) {
      _error = '할 일 저장 실패: $e';
    }

    notifyListeners();
  }

  Future<void> addTodo({
    required String title,
    required int minutes,
    required bool requiresTravel,
  }) async {
    final nextId = _todos.isEmpty
        ? 1
        : _todos.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;

    _todos.add(
      TodoItem(
        id: nextId,
        title: title,
        estimatedMinutes: minutes,
        requiresTravel: requiresTravel,
      ),
    );

    await _persist();
  }

  Future<void> updateTodo(TodoItem updated) async {
    final index = _todos.indexWhere((item) => item.id == updated.id);

    if (index == -1) return;

    _todos[index] = updated;
    await _persist();
  }

  Future<void> toggleCompleted(TodoItem todo) async {
    await updateTodo(todo.copyWith(isCompleted: !todo.isCompleted));
  }

  Future<void> deleteTodo(int id) async {
    _todos.removeWhere((item) => item.id == id);
    await _persist();
  }
}

class TodoScope extends InheritedNotifier<TodoController> {
  const TodoScope({
    super.key,
    required TodoController controller,
    required super.child,
  }) : super(notifier: controller);

  static TodoController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TodoScope>();

    assert(scope != null, 'TodoScope를 찾을 수 없습니다.');
    return scope!.notifier!;
  }
}

//할 일 목록 관ㄹ리 및 화면에 변경사항제공,홈 화면,할 일 화면, 결과화면이 같은 데이터 공유
