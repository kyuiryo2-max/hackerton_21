import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/api_config.dart';

class ServerAskResponse {
  const ServerAskResponse({required this.answer, this.question, this.needsConfirm = false,
    this.todo, this.result, this.intents = const [], this.engine});
  final String answer;
  final String? question;
  final bool needsConfirm;
  final Map<String, dynamic>? todo;
  final Map<String, dynamic>? result;
  final List<Map<String, dynamic>> intents;
  final String? engine;
}

class ServerAskService {
  ServerAskService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  /// [trip]: 이동 중이면 지금 단계와 시각 (11/13, TripPlan.toAskJson). 서버가 그 값으로 답해요.
  Future<ServerAskResponse> ask(String text, {Map<String, dynamic>? trip}) async {
    final response = await _client.post(ApiConfig.endpoint('/api/ask'),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode({'user_id': ApiConfig.userId, 'text': text, 'demo': ApiConfig.demoMode,
        if (trip != null) 'trip': trip}),
    ).timeout(const Duration(seconds: 40));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      final err = decoded is Map ? decoded['error'] : null;
      throw Exception(err is Map ? (err['message'] ?? '질문 실패') : '질문 실패 (HTTP ${response.statusCode})');
    }
    if (decoded is! Map<String, dynamic>) throw const FormatException('질문 응답 형식 오류');
    final answer = decoded['answer']?.toString() ?? '';
    if (answer.isEmpty) throw const FormatException('서버에 answer 값이 없습니다.');
    return ServerAskResponse(answer: answer,
      question: decoded['question']?.toString(),
      needsConfirm: decoded['needs_confirm'] == true,
      todo: decoded['todo'] is Map ? Map<String, dynamic>.from(decoded['todo'] as Map) : null,
      result: decoded['result'] is Map ? Map<String, dynamic>.from(decoded['result'] as Map) : null,
      intents: decoded['intents'] is List ? (decoded['intents'] as List).whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e)).toList() : const [],
      engine: decoded['engine']?.toString());
  }
  void dispose() => _client.close();
}
