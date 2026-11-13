import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/place.dart';
import '../models/todo_item.dart';

/// 할 일 하나 + 그 일을 할 수 있는 가까운 장소 하나
class NearbySpot {
  const NearbySpot({required this.todo, required this.place, required this.meters});

  final TodoItem todo;
  final Place place;
  final int meters;

  /// 직선거리 × 1.3 을 분당 67m(시속 4km)로 걸었을 때
  int get walkMinutes => math.max(1, (meters * 1.3 / 67).round());

  String get distanceLabel => meters < 1000 ? '${(meters / 10).round() * 10}m' : '${(meters / 100).round() / 10}km';
}

/// 평상시 홈: 할 일 목록의 장소 종류(편의점, 다이소…)로 내 주변 장소를 찾아요.
/// 서버의 이름 검색(/api/places/search)을 쓰고, 거리 계산·정렬은 앱에서 해요.
class NearbyTodoService {
  NearbyTodoService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  /// 홈에 보여 주는 최대 개수 (많으면 보기 어려워요)
  static const int maxSpots = 5;
  /// 이보다 먼 곳은 "근처"로 안 봐요
  static const int maxMeters = 2000;

  final Map<String, List<Place>> _cache = {};

  static List<String> keywordsOf(TodoItem t) {
    if (t.placeTypes.isNotEmpty) return t.placeTypes;
    final name = t.placeName?.trim();
    return name == null || name.isEmpty ? const [] : [name];
  }

  Future<List<NearbySpot>> find(List<TodoItem> todos, double lat, double lng, {String? region}) async {
    final spots = <NearbySpot>[];
    for (final todo in todos) {
      if (todo.isCompleted) continue;
      NearbySpot? best;
      for (final kw in keywordsOf(todo)) {
        final places = await _search(kw, lat, lng, region);
        for (final p in places) {
          final m = _meters(lat, lng, p.latitude, p.longitude);
          if (m > maxMeters) continue;
          if (best == null || m < best.meters) best = NearbySpot(todo: todo, place: p, meters: m);
        }
      }
      if (best != null) spots.add(best);
    }
    // "꼭" 할 일 먼저, 그다음 가까운 순
    spots.sort((a, b) {
      final imp = (b.todo.important ? 1 : 0).compareTo(a.todo.important ? 1 : 0);
      return imp != 0 ? imp : a.meters.compareTo(b.meters);
    });
    return spots.take(maxSpots).toList();
  }

  Future<List<Place>> _search(String keyword, double lat, double lng, String? region) async {
    // 동네 이름을 붙이면 카카오 검색이 근처 결과를 더 잘 줘요 (예: "안암동 편의점")
    final area = region?.split(' ').where((w) => w.isNotEmpty).lastOrNull;
    final query = area == null ? keyword : '$area $keyword';
    final key = '$query|${lat.toStringAsFixed(3)},${lng.toStringAsFixed(3)}';
    final cached = _cache[key];
    if (cached != null) return cached;
    try {
      final uri = ApiConfig.endpoint('/api/places/search', {
        'query': query,
        'lat': lat.toStringAsFixed(6),
        'lng': lng.toStringAsFixed(6),
      });
      final res = await _client.get(uri, headers: {'Accept': 'application/json'}).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! List) return const [];
      final found = <Place>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final la = _num(item['lat']), ln = _num(item['lng']);
        if (la == null || ln == null) continue;
        found.add(Place(
          id: '${item['name']}_${la}_$ln',
          name: '${item['name'] ?? keyword}',
          address: '${item['address'] ?? ''}',
          latitude: la,
          longitude: ln,
        ));
      }
      _cache[key] = found;
      return found;
    } catch (_) {
      return const [];
    }
  }

  static double? _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v');

  static int _meters(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180, dLng = (lng2 - lng1) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) * math.cos(lat2 * math.pi / 180) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return (2 * r * math.asin(math.sqrt(a))).round();
  }

  void dispose() => _client.close();
}
