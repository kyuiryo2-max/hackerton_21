import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sync_ro_app/models/memo.dart';
import 'package:sync_ro_app/services/memo_classifier.dart';

void main() {
  test('clear local cases are classified without the server', () async {
    final classifier = MemoClassifier(
      client: MockClient((_) async => http.Response('{}', 500)),
    );

    expect(
      (await classifier.classify('내일 오후 3시 치과 예약')).type,
      MemoType.schedule,
    );
    expect((await classifier.classify('우유 사기')).type, MemoType.todo);
    expect((await classifier.classify('내일 우유 사기')).type, MemoType.todo);
    expect((await classifier.classify('3시')).type, MemoType.schedule);
    expect((await classifier.classify('매주 일요일 교회')).type, MemoType.schedule);

    classifier.dispose();
  });

  test('ambiguous memo can use the existing AI response', () async {
    final classifier = MemoClassifier(
      client: MockClient(
        (_) async => http.Response(
          '{"result":{"intent":"add_schedule"}}',
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );

    final result = await classifier.classify('친구 만나기');
    expect(result.type, MemoType.schedule);
    expect(result.usedAi, isTrue);

    classifier.dispose();
  });
}
