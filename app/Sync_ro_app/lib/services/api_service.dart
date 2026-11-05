
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

class ApiService {
  final http.Client _client;

  ApiService({http.Client? client})
      : _client = client ?? http.Client();

  Future<dynamic> get(String endpoint) async {
    final uri = Uri.parse(
      '${ApiConfig.baseUrl}$endpoint',
    );

    final response = await _client
        .get(
          uri,
          headers: {
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(seconds: 10));

    if (response.statusCode != 200) {
      throw Exception(
        '서버 요청 실패: ${response.statusCode}',
      );
    }

    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  void dispose() {
    _client.close();
  }
}
//서버에 요청을 보내는 역할만 함.