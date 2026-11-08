import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';
import '../config/place_search_config.dart';
import '../data/mock_places.dart';
import '../models/place.dart';

class PlaceSearchService {
  static const List<Place> _demoPlaces = [
    Place(id: 'demo-stop-08301', name: '안암역3번출구', address: '서울특별시 성북구 안암역3번출구 정류장', latitude: 37.58624821, longitude: 127.03045087),
    Place(id: 'demo-destination', name: '청량리역', address: '서울특별시 동대문구 청량리역', latitude: 37.58029, longitude: 127.04691),
  ];

  List<Place> _local(String keyword) {
    final lower = keyword.toLowerCase().replaceAll(' ', '');
    return [..._demoPlaces, ...mockPlaces].where((p) =>
      p.name.toLowerCase().replaceAll(' ', '').contains(lower) ||
      p.address.toLowerCase().replaceAll(' ', '').contains(lower)).toList();
  }

  Future<List<Place>> searchPlaces(String query) async {
    final keyword = query.trim();
    if (keyword.isEmpty) return [];
    final local = _local(keyword);
    if (ApiConfig.offlineDemo || !PlaceSearchConfig.useRealApi) return local;
    try {
      final uri = ApiConfig.endpoint('/api/places/search', {'query': keyword});
      final response = await http.get(uri, headers: {'Accept': 'application/json'})
          .timeout(PlaceSearchConfig.timeout);
      if (response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 501) {
        return local; // Endpoint unavailable: known demo/sample places remain searchable.
      }
      if (response.statusCode != 200) throw Exception('HTTP ${response.statusCode}');
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      final dynamic raw = decoded is List ? decoded : decoded is Map ?
          (decoded['places'] ?? decoded['results'] ?? decoded['data']) : null;
      if (raw is! List) throw const FormatException('장소 목록 형식이 올바르지 않습니다.');
      final found = <Place>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final location = item['location'];
        final coords = location is Map ? location : item;
        final lat = _number(coords['latitude'] ?? coords['lat'] ?? item['latitude']);
        final lng = _number(coords['longitude'] ?? coords['lng'] ?? coords['lon'] ?? item['longitude']);
        if (lat == null || lng == null) continue;
        found.add(Place(id: (item['id'] ?? item['place_id'] ?? '${lat}_$lng').toString(),
          name: (item['name'] ?? item['place_name'] ?? '이름 없는 장소').toString(),
          address: (item['address'] ?? item['road_address'] ?? '').toString(),
          latitude: lat, longitude: lng));
      }
      return [...found, ...local.where((p) => !found.any((f) => f.name == p.name))];
    } catch (_) {
      // Search only known local/demo places while API is offline. Do not invent results.
      if (local.isNotEmpty) return local;
      rethrow;
    }
  }
  double? _number(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v');
}
