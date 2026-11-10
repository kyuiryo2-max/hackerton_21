import '../data/offline_demo_data.dart';

/// Deterministic scenario answer lookup. No external server or AI call.
class OfflineAskService {
  String reply(String question) {
    final text = question.trim().replaceAll(' ', '').toLowerCase();
    final samples = OfflineDemoData.answers;
    if (text.isEmpty) return '질문을 입력해 주세요.';
    if (text.contains('버스') || text.contains('2115') || text.contains('도착')) {
      return _answer(samples[0]);
    }
    if (text.contains('이어폰') || text.contains('편의점') || text.contains('cu')) {
      return _answer(samples[1]);
    }
    if (text.contains('거기') || text.contains('어디') || text.contains('들러도')) {
      return _answer(samples[2]);
    }
    return _answer(samples[3]);
  }

  String _answer(Map<String, dynamic> sample) =>
      '${sample['answer'] ?? sample['question'] ?? '시연 답변이 없습니다.'}\n\n'
      '※ 저장된 API 예시를 사용하는 오프라인 시연 답변입니다. 실제 분석 결과가 아닙니다.';
}
