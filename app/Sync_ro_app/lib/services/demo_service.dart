import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../data/offline_demo_data.dart';

class DemoService {
  final http.Client _client;
  DemoService({http.Client? client}) : _client = client ?? http.Client();

  Future<Map<String, dynamic>> getContext() async => ApiConfig.offlineDemo
      ? OfflineDemoData.context : _get('/api/demo/context');

  Future<List<BusArrival>> getArrivals({String stopId = '08301', int? elapsedSeconds}) async {
    if (ApiConfig.offlineDemo) {
      final body = OfflineDemoData.arrivals(elapsedSeconds: elapsedSeconds ?? 0);
      return (body['arrivals'] as List).whereType<Map>().map((item) =>
          BusArrival.fromJson(Map<String, dynamic>.from(item))).toList();
    }
    final query = <String, String>{'stop_id': stopId, 'demo': 'true'};
    if (elapsedSeconds != null) query['elapsed_seconds'] = '$elapsedSeconds';
    final data = await _get('/api/arrivals', query);
    final list = data['arrivals'];
    if (list is! List) throw const FormatException('arrivals 배열을 찾을 수 없습니다.');
    return list.whereType<Map>().map((item) => BusArrival.fromJson(Map<String, dynamic>.from(item))).toList();
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    final response = await _client.get(ApiConfig.endpoint(path, query),
      headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 25));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception('시연 API 실패 (HTTP ${response.statusCode}): $decoded');
    }
    if (decoded is! Map) throw const FormatException('JSON 객체를 기대했습니다.');
    return Map<String, dynamic>.from(decoded);
  }

  void dispose() => _client.close();
}

class BusArrival {
  final String route;
  final int minutes;
  final int? nextMinutes;
  final String direction;
  const BusArrival({required this.route, required this.minutes, required this.nextMinutes, required this.direction});
  factory BusArrival.fromJson(Map<String, dynamic> json) => BusArrival(
    route: '${json['route'] ?? '-'}',
    minutes: (json['minutes'] as num?)?.toInt() ?? 0,
    nextMinutes: (json['next_minutes'] as num?)?.toInt(),
    direction: '${json['direction'] ?? ''}',
  );
}
