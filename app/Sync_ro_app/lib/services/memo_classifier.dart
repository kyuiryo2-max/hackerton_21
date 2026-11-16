import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';
import '../models/memo.dart';

enum MemoClassificationSource { local, ai }

/// 위젯 하단 입력줄에서 받은 한 줄 메모의 분류 결과.
class MemoClassification {
  const MemoClassification({
    required this.type,
    required this.reason,
    required this.source,
  });

  final MemoType type;
  final String reason;
  final MemoClassificationSource source;

  bool get usedAi => source == MemoClassificationSource.ai;
}

/// 메모를 '할일'과 '일정' 두 칸으로 나눠요.
///
/// 기존 AI(/api/ask)는 이동·경로 질문에 맞춰져 있어 "내일 3시 병원" 같은
/// 일반 메모를 항상 분류하지는 못해요. 그래서 날짜·시간·동작어가 분명한
/// 문장은 기기에서 바로 나누고, 애매한 문장만 기존 AI에 한 번 더 물어봐요.
/// 서버가 꺼져 있거나 응답이 늦으면 기기 분류 결과를 그대로 써요.
class MemoClassifier {
  MemoClassifier({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  bool _closed = false;

  static final RegExp _dateTimePattern = RegExp(
    r'(오늘|내일|모레|글피|이번\s*주|다음\s*주|월요일|화요일|수요일|목요일|금요일|토요일|일요일|'
    r'\d{1,2}\s*월\s*\d{1,2}\s*일|\d{1,2}\s*일|\d{1,2}\s*시|\d{1,2}:\d{2}|'
    r'오전|오후|아침|점심|저녁|밤|자정|정오|까지|부터)',
  );

  static final RegExp _schedulePattern = RegExp(
    r'(일정|약속|예약|미팅|회의|수업|면접|병원|치과|공항|터미널|기차|비행기|'
    r'출발|도착|데이트|모임|세미나|발표|시험|마감|데드라인|결혼식|장례식|'
    r'행사|공연|관람|상담|검진|수술|이사)',
  );

  static final RegExp _todoPattern = RegExp(
    r'(사기|사야|구매|준비|제출|숙제|과제|청소|빨래|연락|전화|확인|신청|결제|'
    r'충전|챙기|가져가|먹기|마시기|만들기|정리|복사|출력|보내기|올리기|'
    r'다운로드|설치|업데이트|예매|장보기|은행|우체국|약\s*사|티켓|'
    r'슬리퍼|실내화|음료|생수|물건|문구|볼펜|노트|다이소|편의점)',
  );

  Future<MemoClassification> classify(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) {
      return const MemoClassification(
        type: MemoType.todo,
        reason: '내용이 없어 할일로 두었어요.',
        source: MemoClassificationSource.local,
      );
    }

    final local = _classifyLocally(text);
    if (local.strong) return local.result;

    final ai = await _askServer(text);
    return ai ?? local.result;
  }

  _LocalClassification _classifyLocally(String text) {
    final hasDateTime = _dateTimePattern.hasMatch(text);
    final hasScheduleWord = _schedulePattern.hasMatch(text);
    final hasTodoWord = _todoPattern.hasMatch(text);

    if (hasScheduleWord && !hasTodoWord) {
      return _LocalClassification(
        strong: true,
        result: MemoClassification(
          type: MemoType.schedule,
          reason: hasDateTime
              ? '날짜·시간과 일정 표현이 있어 일정으로 분류했어요.'
              : '일정 관련 표현이 있어 일정으로 분류했어요.',
          source: MemoClassificationSource.local,
        ),
      );
    }

    if (hasTodoWord && !hasScheduleWord) {
      return _LocalClassification(
        strong: true,
        result: const MemoClassification(
          type: MemoType.todo,
          reason: '할 일 표현이 있어 할일로 분류했어요.',
          source: MemoClassificationSource.local,
        ),
      );
    }

    if (hasDateTime && !hasScheduleWord && !hasTodoWord) {
      return _LocalClassification(
        strong: true,
        result: const MemoClassification(
          type: MemoType.schedule,
          reason: '날짜·시간 표현이 있어 일정으로 분류했어요.',
          source: MemoClassificationSource.local,
        ),
      );
    }

    // "내일 우유 사기"처럼 시간과 할 일이 같이 있으면 할 일을 우선해요.
    // "내일 3시 병원 예약"처럼 일정 단어까지 있으면 일정으로 봐요.
    if (hasDateTime && hasScheduleWord && hasTodoWord) {
      return _LocalClassification(
        strong: true,
        result: MemoClassification(
          type: MemoType.schedule,
          reason: '날짜·시간과 일정 표현이 함께 있어 일정으로 분류했어요.',
          source: MemoClassificationSource.local,
        ),
      );
    }

    if (hasDateTime && hasTodoWord) {
      return _LocalClassification(
        strong: true,
        result: const MemoClassification(
          type: MemoType.todo,
          reason: '할 일 표현이 있어 할일로 분류했어요.',
          source: MemoClassificationSource.local,
        ),
      );
    }

    // "친구 만나기"처럼 단서가 적은 문장만 기존 AI에 확인해요.
    return _LocalClassification(
      strong: false,
      result: const MemoClassification(
        type: MemoType.todo,
        reason: '할 일로 분류했어요.',
        source: MemoClassificationSource.local,
      ),
    );
  }

  Future<MemoClassification?> _askServer(String text) async {
    if (_closed) return null;
    try {
      final response = await _client
          .post(
            ApiConfig.endpoint('/api/ask'),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({
              'user_id': 'memo-widget-classifier',
              'text': text,
              'demo': true,
            }),
          )
          .timeout(const Duration(seconds: 6));
      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) return null;

      final intents = <String>[];
      final result = decoded['result'];
      if (result is Map && result['intent'] != null) {
        intents.add(result['intent'].toString());
      }
      final rawIntents = decoded['intents'];
      if (rawIntents is List) {
        for (final item in rawIntents) {
          if (item is Map && item['intent'] != null) {
            intents.add(item['intent'].toString());
          }
        }
      }

      if (intents.contains('add_schedule') || decoded['schedule'] is Map) {
        return const MemoClassification(
          type: MemoType.schedule,
          reason: 'AI가 일정으로 판단했어요.',
          source: MemoClassificationSource.ai,
        );
      }
      if (intents.any(
        (intent) =>
            intent == 'add_todo' ||
            intent == 'stopover_check' ||
            intent == 'change_todo',
      )) {
        return const MemoClassification(
          type: MemoType.todo,
          reason: 'AI가 할일로 판단했어요.',
          source: MemoClassificationSource.ai,
        );
      }
    } catch (_) {
      // 네트워크가 없거나 서버가 일반 메모를 이해하지 못하면 기기 분류로.
    }
    return null;
  }

  void dispose() {
    _closed = true;
    _client.close();
  }
}

class _LocalClassification {
  const _LocalClassification({required this.strong, required this.result});

  final bool strong;
  final MemoClassification result;
}
