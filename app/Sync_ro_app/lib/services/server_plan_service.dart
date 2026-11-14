import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class ServerPlan {
  const ServerPlan(this.data);
  final Map<String, dynamic> data;
  DateTime? get boardAt => DateTime.tryParse(_top('board_at')?.toString() ?? '');
  DateTime? get arriveAt => DateTime.tryParse(_top('arrive_at')?.toString() ?? '');

  /// 서버가 준 경로 전부 (운행하지 않는 경로 포함)
  List<Map<String, dynamic>> get allRoutes => (data['routes'] as List? ?? const [])
      .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  /// 지금 탈 수 있는 경로만 (11/15).
  /// 지금 바로 출발하는 계획(basis realtime/now)인데 탈 정류장·역에 실시간 도착 정보가 하나도 없으면
  /// 그 노선은 지금 운행하지 않는 걸로 보고 빼요. 예: 새벽 1시 50분의 지하철.
  /// 일정이 멀어서 도착 시각에서 거꾸로 계산한 계획(arrive_by)은 실시간을 안 보니까 그대로 둬요.
  List<Map<String, dynamic>> get routes => allRoutes.where((r) => !notRunning(r)).toList();

  bool notRunning(Map<String, dynamic> r) {
    final basis = '${r['basis'] ?? data['basis'] ?? ''}';
    if (basis != 'realtime' && basis != 'now') return false;
    if ('${r['type'] ?? ''}'.toUpperCase().contains('WALK')) return false;
    if (r['has_realtime'] == true) return false;
    final soon = r['next_vehicles_min'];
    return !(soon is List && soon.isNotEmpty);
  }

  /// 경로는 받았는데 지금 운행하는 게 하나도 없어요 (막차가 끊긴 시간 등)
  bool get noServiceNow => allRoutes.isNotEmpty && routes.isEmpty;

  /// 맨 위 시각(board_at 등)은 서버 1순위 경로 기준이라, 그 경로가 빠졌으면 남은 첫 경로의 값을 써요
  dynamic _top(String key) {
    final all = allRoutes, live = routes;
    if (live.isNotEmpty && live.length != all.length && live.first[key] != null) return live.first[key];
    return data[key];
  }
  List<Map<String, dynamic>> get todos => (data['todos'] as List? ?? const [])
      .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  String get explanation => data['explanation']?.toString() ?? '';

  /// 경로 하나만 남긴 계획 (11/13). 서버가 경로마다 준 출발·탑승·도착 시각으로 바꿔요.
  /// 홈과 이동 탭이 사용자가 고른 같은 경로로 계산하게 하려고요. 그 순위가 없으면 그대로예요.
  ServerPlan forRank(int rank) {
    final match = routes.where((r) => (r['rank'] as num?)?.toInt() == rank);
    if (match.isEmpty) return this;
    final r = match.first;
    final out = Map<String, dynamic>.from(data)..['routes'] = [r];
    if (r['depart_at'] != null) {
      for (final key in ['basis', 'depart_at', 'board_at', 'arrive_at']) {
        out[key] = r[key];
      }
    }
    return ServerPlan(out);
  }
  // 서버가 depart_at(늦어도 출발할 시각, 11/13)을 주면 그 값을 쓰고, 없으면 전체 소요시간으로 역산.
  // basis: arrive_by(도착 시각에서 거꾸로) / realtime(실시간 차) / now(지금 출발)
  String? get basis => data['basis']?.toString();
  DateTime? get departureAt {
    final direct = DateTime.tryParse((_top('depart_at') ?? data['departure_at'])?.toString() ?? '');
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
