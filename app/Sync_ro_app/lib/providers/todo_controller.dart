import 'active_route_controller.dart';
import '../services/real_data_service.dart';
import '../config/runtime_mode.dart';
import 'package:flutter/material.dart';

import '../data/mock_todos.dart';
import '../models/todo_item.dart';
import '../services/todo_storage_service.dart';

class TodoController extends ChangeNotifier {
  final TodoStorageService _storage = TodoStorageService();
  final RealDataService _remote = RealDataService();

  List<TodoItem> _todos = [];
  bool _isLoading = true;
  String? _error;

  List<TodoItem> get todos => List.unmodifiable(_todos);

  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> initialize() async {
    try {
      final saved = await _storage.loadTodos();
      _todos = RuntimeMode.instance.isDemo
          ? saved ?? List.of(mockTodos)
          : await _remote.loadTodos(previous: saved ?? <TodoItem>[]);
      _error = null;
    } catch (e) {
      _error = '할 일 불러오기 실패: $e';
      _todos = RuntimeMode.instance.isDemo ? List.of(mockTodos) : <TodoItem>[];
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

  /// 저장된 할 일을 돌려줘요 (할 일·일정 탭에서 날짜를 붙일 때 써요).
  Future<TodoItem> addTodo({
    required String title,
    required int minutes,
    required bool requiresTravel,
    String? placeName,
    String? placeType,
  }) async {
    final nextId = _todos.isEmpty
        ? 1
        : _todos.map((e) => e.id).reduce((a, b) => a > b ? a : b) + 1;

    final draft = TodoItem(
      id: nextId, title: title, estimatedMinutes: minutes,
      requiresTravel: requiresTravel || (placeType?.isNotEmpty ?? false), placeName: placeName,
    );
    final saved = RuntimeMode.instance.isDemo
        ? draft : await _remote.createTodo(title: title, minutes: minutes, placeType: placeType);
    _todos.add(saved);

    await _persist();
    activeRouteController.requestPlanRefresh();
    return saved;
  }

  Future<void> updateTodo(TodoItem updated, {String? placeType}) async {
    final index = _todos.indexWhere((item) => item.id == updated.id);

    if (index == -1) return;

    final saved = RuntimeMode.instance.isDemo
        ? updated.copyWith(requiresTravel: (placeType?.isNotEmpty ?? false) || updated.requiresTravel)
        : await _remote.updateTodo(updated, previous: _todos[index], placeType: placeType);
    _todos[index] = saved;
    await _persist();
    activeRouteController.requestPlanRefresh();
  }

  Future<void> toggleCompleted(TodoItem todo) async {
    await updateTodo(todo.copyWith(isCompleted: !todo.isCompleted));
  }

  Future<void> deleteTodo(int id) async {
    if (!RuntimeMode.instance.isDemo) await _remote.deleteTodo(id);
    _todos.removeWhere((item) => item.id == id);
    await _persist();
    activeRouteController.requestPlanRefresh();
  }
  @override
  void dispose() {
    _remote.dispose();
    super.dispose();
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
