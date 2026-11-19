import '../data/offline_demo_data.dart';

/// Deterministic scenario answer lookup. No external server or AI call.
class OfflineAskService {
  String reply(String question) {
    final text = question.trim().replaceAll(' ', '').toLowerCase();
    final samples = OfflineDemoData.answers;
    if (text.isEmpty) return '질문을 입력해 주세요.';
    if (text.contains('173')) {
      return '173번이 5분 뒤에 와요. 서울역버스환승센터에서 타면 '
          '9시 17분에 고려대학교에 도착해요.\n\n'
          '※ 저장된 API 예시를 사용하는 오프라인 시연 답변입니다. 실제 분석 결과가 아닙니다.';
    }
    if (text.contains('버스') ||
        text.contains('지하철') ||
        text.contains('호선') ||
        text.contains('다음차') ||
        text.contains('도착')) {
      return '1호선·6호선이 9분 뒤에 와요. 동묘앞에서 6호선으로 갈아타면 '
          '9시 12분에 고려대학교에 도착해요.\n\n'
          '※ 저장된 API 예시를 사용하는 오프라인 시연 답변입니다. 실제 분석 결과가 아닙니다.';
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
