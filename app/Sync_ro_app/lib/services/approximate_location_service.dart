import 'dart:convert';

import 'package:http/http.dart' as http;

/// Converts GPS coordinates into an approximate region, not a street address.
/// For production traffic, replace the public endpoint with a backend proxy.
class ApproximateLocationService {
  static const String endpoint = String.fromEnvironment(
    'REVERSE_GEOCODE_URL',
    defaultValue: 'https://nominatim.openstreetmap.org/reverse',
  );

  Future<String?> regionFor(double latitude, double longitude) async {
    final uri = Uri.parse(endpoint).replace(queryParameters: {
      'lat': latitude.toStringAsFixed(6),
      'lon': longitude.toStringAsFixed(6),
      'format': 'json',
      'addressdetails': '1',
      'zoom': '14',
      'layer': 'address',
      'accept-language': 'ko',
    });

    final response = await http.get(
      uri,
      headers: {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('주소 조회 실패 (HTTP ${response.statusCode})');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body is! Map || body['address'] is! Map) return null;
    final address = Map<String, dynamic>.from(body['address'] as Map);

    String? first(List<String> keys) {
      for (final key in keys) {
        final value = address[key]?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
      return null;
    }

    final province = first(['state', 'province', 'region']);
    final city = first(['city', 'municipality', 'town']);
    final district = first(['city_district', 'borough', 'county', 'district']);
    final neighborhood = first([
      'suburb', 'quarter', 'neighbourhood', 'village', 'hamlet',
    ]);

    final segments = <String>[];
    for (final value in [province, city, district, neighborhood]) {
      if (value == null) continue;
      // Some areas repeat city/state or district/suburb names.
      if (segments.contains(value)) continue;
      segments.add(value);
    }
    if (segments.isEmpty) return null;
    // Limit the amount of precision displayed on the home screen.
    return segments.take(3).join(' ');
  }
}
