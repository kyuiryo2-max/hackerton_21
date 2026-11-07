import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/assistant_config.dart';
import '../models/assistant_analysis.dart';

class AssistantApiService {
  final http.Client _client = http.Client();

  Future<AssistantAnalysis> analyze(String message) async {
    final response = await _client.post(
      Uri.parse('${AssistantConfig.baseUrl}/api/assistant/analyze'),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode({'message': message}),
    ).timeout(const Duration(seconds: 35));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      final error = decoded is Map ? decoded['detail'] ?? decoded['error'] : null;
      throw Exception('서버 오류 (${response.statusCode}): ${error ?? '알 수 없음'}');
    }
    if (decoded is! Map || decoded['analysis'] is! Map) {
      throw const FormatException('분석 결과 형식이 올바르지 않습니다.');
    }
    return AssistantAnalysis.fromJson(
      Map<String, dynamic>.from(decoded['analysis'] as Map),
      decoded['provider']?.toString() ?? 'unknown',
    );
  }

  void dispose() => _client.close();
}
