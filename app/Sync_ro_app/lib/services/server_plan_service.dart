import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class ServerPlan {
  const ServerPlan(this.data);
  final Map<String, dynamic> data;
  DateTime? get boardAt => DateTime.tryParse(data['board_at']?.toString() ?? '');
  DateTime? get arriveAt => DateTime.tryParse(data['arrive_at']?.toString() ?? '');
  List<Map<String, dynamic>> get routes => (data['routes'] as List? ?? const [])
      .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  List<Map<String, dynamic>> get todos => (data['todos'] as List? ?? const [])
      .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  String get explanation => data['explanation']?.toString() ?? '';
  // 서버가 departure_at을 제공하면 우선 사용하고, 없으면 전체 소요시간으로 역산.
  DateTime? get departureAt {
    final direct = DateTime.tryParse(data['departure_at']?.toString() ?? '');
    if (direct != null) return direct;
    final arrival = arriveAt;
    final minutes = routes.isEmpty ? null : (routes.first['total_min'] as num?)?.toInt();
    return arrival == null || minutes == null ? null : arrival.subtract(Duration(minutes: minutes));
  }
  bool get departureDerived => data['departure_at'] == null;
}

class ServerPlanService {
  ServerPlanService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  Future<ServerPlan> fetch({List<int>? todoIds, double? originLat, double? originLng}) async {
    final body = <String, dynamic>{
      'user_id': ApiConfig.userId,
      'demo': ApiConfig.demoMode,
      if (todoIds != null) 'todo_ids': todoIds,
      if (!ApiConfig.demoMode && originLat != null && originLng != null)
        'origin': {'lat': originLat, 'lng': originLng},
    };
    final response = await _client.post(ApiConfig.endpoint('/api/plan'),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(body)).timeout(const Duration(seconds: 30));
    final parsed = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      final error = parsed is Map ? parsed['error'] : null;
      final message = error is Map ? error['message'] : null;
      throw Exception(message ?? '계획 요청 실패 (HTTP ${response.statusCode})');
    }
    if (parsed is! Map<String, dynamic> || parsed['routes'] is! List) {
      throw const FormatException('계획 응답의 routes 형식이 올바르지 않습니다.');
    }
    return ServerPlan(parsed);
  }
  void dispose() => _client.close();
}
