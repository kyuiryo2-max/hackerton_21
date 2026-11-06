import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/place_search_config.dart';
import '../data/mock_places.dart';
import '../models/place.dart';

class PlaceSearchService {
  Future<List<Place>> searchPlaces(String query) async {
    final keyword = query.trim();

    if (keyword.isEmpty) {
      return [];
    }

    if (!PlaceSearchConfig.useRealApi) {
      return _searchMockPlaces(keyword);
    }

    return _searchRealPlaces(keyword);
  }

  List<Place> _searchMockPlaces(String keyword) {
    final normalized = keyword.toLowerCase();

    return mockPlaces.where((place) {
      return place.name.toLowerCase().contains(normalized) ||
          place.address.toLowerCase().contains(normalized);
    }).toList();
  }

  Future<List<Place>> _searchRealPlaces(String keyword) async {
    final baseUrl = PlaceSearchConfig.baseUrl.replaceFirst(RegExp(r'/$'), '');

    final uri = Uri.parse(
      '$baseUrl/api/places/search',
    ).replace(queryParameters: {'query': keyword});

    final response = await http.get(uri).timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception('장소 검색 실패: HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(utf8.decode(response.bodyBytes));

    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('장소 검색 응답 형식이 올바르지 않습니다.');
    }

    final placesJson = decoded['places'];

    if (placesJson is! List) {
      throw const FormatException('places 목록이 없습니다.');
    }

    return placesJson.map((item) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('장소 데이터 형식이 올바르지 않습니다.');
      }

      return Place(
        id: item['id'].toString(),
        name: item['name'].toString(),
        address: item['address'].toString(),
        latitude: (item['latitude'] as num).toDouble(),
        longitude: (item['longitude'] as num).toDouble(),
      );
    }).toList();
  }
}
