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
  // 서버가 depart_at(늦어도 출발할 시각, 11/13)을 주면 그 값을 쓰고, 없으면 전체 소요시간으로 역산.
  // basis: arrive_by(도착 시각에서 거꾸로) / realtime(실시간 차) / now(지금 출발)
  String? get basis => data['basis']?.toString();
  DateTime? get departureAt {
    final direct = DateTime.tryParse((data['depart_at'] ?? data['departure_at'])?.toString() ?? '');
    if (direct != null) return direct;
    final arrival = arriveAt;
    final minutes = routes.isEmpty ? null : (routes.first['total_min'] as num?)?.toInt();
    return arrival == null || minutes == null ? null : arrival.subtract(Duration(minutes: minutes));
  }
  bool get departureDerived => data['depart_at'] == null && data['departure_at'] == null;
}

class ServerPlanService {
  ServerPlanService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  /// [destinationLat]·[destinationLng]를 주면 일정 없이 "지금 출발" 기준으로 계산해요 (홈 검색창, 직접 검색).
  Future<ServerPlan> fetch({int? scheduleId, List<int>? todoIds, double? originLat, double? originLng,
      String? destinationName, double? destinationLat, double? destinationLng}) async {
    final body = <String, dynamic>{
      'user_id': ApiConfig.userId,
      'demo': ApiConfig.demoMode,
      if (!ApiConfig.demoMode && scheduleId != null) 'schedule_id': scheduleId,
      if (todoIds != null) 'todo_ids': todoIds,
      if (!ApiConfig.demoMode && originLat != null && originLng != null)
        'origin': {'lat': originLat, 'lng': originLng},
      if (!ApiConfig.demoMode && destinationLat != null && destinationLng != null)
        'destination': {'name': destinationName ?? '', 'lat': destinationLat, 'lng': destinationLng},
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
