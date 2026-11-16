import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_ro_app/models/todo_item.dart';
import 'package:sync_ro_app/services/real_data_service.dart';

http.Response _jsonResponse(Object body, [int statusCode = 200]) {
  return http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    statusCode,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

Map<String, dynamic> _todoJson({String? placeName}) {
  return {
    'id': 7,
    'user_id': 'demo',
    'text': '약 사기',
    'place_types': ['약국'],
    'importance': '선택',
    'status': '대기',
    'source': '입력',
    'stay_minutes': 5,
    'place_name': placeName,
    'done': false,
  };
}

void main() {
  test('할 일을 저장할 때 고른 가게 이름도 서버에 보내요', () async {
    late Map<String, dynamic> sent;
    final service = RealDataService(
      client: MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/todos');
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonResponse(_todoJson(placeName: 'CU 안암센트럴점'), 201);
      }),
    );

    final todo = await service.createTodo(
      title: '약 사기',
      placeTypes: const ['약국'],
      placeName: 'CU 안암센트럴점',
    );

    expect(sent['place_name'], 'CU 안암센트럴점');
    expect(todo.placeName, 'CU 안암센트럴점');
    expect(todo.requiresTravel, isTrue);
    service.dispose();
  });

  test('새로고침 뒤 조회한 서버의 가게 이름을 사용해요', () async {
    final service = RealDataService(
      client: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/todos');
        return _jsonResponse([_todoJson(placeName: 'GS25 안암점')]);
      }),
    );

    final todos = await service.loadTodos();

    expect(todos.single.placeName, 'GS25 안암점');
    expect(todos.single.requiresTravel, isTrue);
    service.dispose();
  });

  test('할 일을 수정할 때 바뀐 가게 이름을 서버에 보내요', () async {
    late Map<String, dynamic> sent;
    final service = RealDataService(
      client: MockClient((request) async {
        expect(request.method, 'PATCH');
        sent = jsonDecode(request.body) as Map<String, dynamic>;
        return _jsonResponse(_todoJson(placeName: 'GS25 안암점'));
      }),
    );
    final previous = const TodoItem(
      id: 7,
      title: '약 사기',
      estimatedMinutes: 5,
      placeName: 'CU 안암센트럴점',
      placeTypes: ['약국'],
    );
    final updated = previous.copyWith(placeName: 'GS25 안암점');

    final saved = await service.updateTodo(updated, previous: previous);

    expect(sent['place_name'], 'GS25 안암점');
    expect(saved.placeName, 'GS25 안암점');
    service.dispose();
  });
}
