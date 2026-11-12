import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../models/schedule.dart';
import '../models/todo_item.dart';

/// Server storage contract from server/app/routers/storage.py.
/// Do not silently fall back to demo or local data after a server write fails.
class RealDataService {
  RealDataService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  String get userId => ApiConfig.userId;

  Future<dynamic> _request(String method, String path, {Map<String, String>? query, Object? body}) async {
    final uri = ApiConfig.endpoint(path, query);
    final headers = <String, String>{'Accept': 'application/json', 'Content-Type': 'application/json; charset=utf-8'};
    late http.Response response;
    if (method == 'GET') {
      response = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 25));
    } else if (method == 'POST') {
      response = await _client.post(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 25));
    } else if (method == 'PATCH') {
      response = await _client.patch(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 25));
    } else if (method == 'DELETE') {
      response = await _client.delete(uri, headers: headers).timeout(const Duration(seconds: 25));
    } else {
      throw ArgumentError('Unsupported method: $method');
    }
    final value = response.body.isEmpty ? null : jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = value is Map ? value['error'] : null;
      final message = error is Map ? error['message'] : null;
      throw Exception(message ?? '서버 요청 실패 (${response.statusCode})');
    }
    return value;
  }

  DateTime _parseKst(String value) {
    final parsed = DateTime.parse(value);
    return parsed.toLocal();
  }

  Schedule _scheduleFromServer(Map<String, dynamic> json, {Schedule? previous}) {
    final start = _parseKst('${json['arrive_by']}');
    return Schedule(
      id: (json['id'] as num).toInt(),
      title: previous?.title ?? '${json['destination']}',
      location: '${json['destination']}',
      destinationPlaceId: previous?.destinationPlaceId,
      destinationAddress: previous?.destinationAddress,
      destinationLatitude: (json['destination_lat'] as num?)?.toDouble(),
      destinationLongitude: (json['destination_lng'] as num?)?.toDouble(),
      originMode: previous?.originMode ?? 'current',
      originPlaceId: previous?.originPlaceId,
      originName: previous?.originName,
      originAddress: previous?.originAddress,
      originLatitude: previous?.originLatitude,
      originLongitude: previous?.originLongitude,
      startTime: start,
      endTime: previous?.endTime ?? start.add(const Duration(hours: 1)),
      preparationMinutes: (json['prep_minutes'] as num?)?.toInt() ?? 30,
    );
  }

  Future<List<Schedule>> loadSchedules({List<Schedule> previous = const []}) async {
    final raw = await _request('GET', '/api/schedules', query: {'user_id': userId});
    if (raw is! List) throw const FormatException('일정 목록 응답 형식 오류');
    final existing = {for (final s in previous) s.id: s};
    return raw.whereType<Map>().map((e) {
      final json = Map<String, dynamic>.from(e);
      return _scheduleFromServer(json, previous: existing[(json['id'] as num).toInt()]);
    }).toList();
  }

  Future<Schedule> createSchedule(Schedule draft) async {
    if (draft.destinationLatitude == null || draft.destinationLongitude == null) {
      throw StateError('실제 모드 일정에는 목적지 좌표가 필요합니다.');
    }
    final raw = await _request('POST', '/api/schedules', body: {
      'user_id': userId, 'destination': draft.location,
      'destination_lat': draft.destinationLatitude,
      'destination_lng': draft.destinationLongitude,
      'arrive_by': draft.startTime.toIso8601String(),
      'prep_minutes': draft.preparationMinutes,
    });
    return _scheduleFromServer(Map<String, dynamic>.from(raw as Map), previous: draft);
  }

  Future<Schedule> updateSchedule(Schedule updated) async {
    if (updated.destinationLatitude == null || updated.destinationLongitude == null) {
      throw StateError('실제 모드 일정에는 목적지 좌표가 필요합니다.');
    }
    final raw = await _request('PATCH', '/api/schedules/${updated.id}', query: {'user_id': userId}, body: {
      'destination': updated.location,
      'destination_lat': updated.destinationLatitude,
      'destination_lng': updated.destinationLongitude,
      'arrive_by': updated.startTime.toIso8601String(),
      'prep_minutes': updated.preparationMinutes,
    });
    return _scheduleFromServer(Map<String, dynamic>.from(raw as Map), previous: updated);
  }

  Future<void> deleteSchedule(int id) async {
    await _request('DELETE', '/api/schedules/$id', query: {'user_id': userId});
  }

  TodoItem _todoFromServer(Map<String, dynamic> json, {TodoItem? previous}) => TodoItem(
    id: (json['id'] as num).toInt(),
    title: '${json['text']}',
    estimatedMinutes: previous?.estimatedMinutes ?? 10,
    requiresTravel: (json['place_types'] is List && (json['place_types'] as List).isNotEmpty),
    isCompleted: json['done'] == true || json['status'] == '완료',
    placeName: previous?.placeName,
  );

  Future<List<TodoItem>> loadTodos({List<TodoItem> previous = const []}) async {
    final raw = await _request('GET', '/api/todos', query: {'user_id': userId});
    if (raw is! List) throw const FormatException('할 일 목록 응답 형식 오류');
    final existing = {for (final t in previous) t.id: t};
    return raw.whereType<Map>().map((e) {
      final json = Map<String, dynamic>.from(e);
      return _todoFromServer(json, previous: existing[(json['id'] as num).toInt()]);
    }).toList();
  }

  Future<List<String>> _parsePlaceTypes(String text) async {
    final analyzed = await _request('POST', '/api/tasks/parse',
        body: {'user_id': userId, 'text': text});
    final parsed = Map<String, dynamic>.from(analyzed as Map);
    return parsed['place_types'] is List
        ? (parsed['place_types'] as List).whereType<String>().toList()
        : <String>[];
  }

  Future<TodoItem> createTodo({required String title, required int minutes,
      String? placeType}) async {
    final places = placeType != null && placeType.isNotEmpty
        ? <String>[placeType] : await _parsePlaceTypes(title);
    // For uncertain classifications, use an empty place list rather than inventing a venue.
    final raw = await _request('POST', '/api/todos', body: {
      'user_id': userId, 'text': title, 'place_types': places,
      'importance': '선택', 'status': '대기', 'source': '입력',
    });
    return _todoFromServer(Map<String, dynamic>.from(raw as Map)).copyWith(estimatedMinutes: minutes);
  }

  Future<TodoItem> updateTodo(TodoItem updated, {TodoItem? previous,
      String? placeType}) async {
    // Explicit place selection takes precedence. Otherwise classify again
    // when the title changes; server stores the updated place_types.
    final titleChanged = previous != null && previous.title != updated.title;
    final places = placeType != null && placeType.isNotEmpty
        ? <String>[placeType]
        : (titleChanged ? await _parsePlaceTypes(updated.title) : null);
    final raw = await _request('PATCH', '/api/todos/${updated.id}',
        query: {'user_id': userId}, body: {
      'text': updated.title,
      'done': updated.isCompleted,
      if (places != null) 'place_types': places,
    });
    return _todoFromServer(Map<String, dynamic>.from(raw as Map), previous: updated);
  }

  Future<void> deleteTodo(int id) async {
    await _request('DELETE', '/api/todos/$id', query: {'user_id': userId});
  }

  void dispose() => _client.close();
}
