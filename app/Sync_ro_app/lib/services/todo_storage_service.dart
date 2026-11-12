import '../config/runtime_mode.dart';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/todo_item.dart';

class TodoStorageService {
  static String get _key => RuntimeMode.instance.isDemo
      ? 'sync_ro_todos_v1' : 'sync_ro_todos_v2_${RuntimeMode.instance.storageNamespace}';

  Future<List<TodoItem>?> loadTodos() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);

    if (raw == null) return null;

    final decoded = jsonDecode(raw) as List;

    return decoded
        .map(
          (item) => TodoItem.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList();
  }

  Future<void> saveTodos(List<TodoItem> todos) async {
    final prefs = await SharedPreferences.getInstance();

    final raw = jsonEncode(todos.map((item) => item.toJson()).toList());

    final success = await prefs.setString(_key, raw);

    if (!success) {
      throw Exception('할 일 저장에 실패했습니다.');
    }
  }
}

//앱이 다시실행되면 로컬저장소에서 할 일 읽어옴
