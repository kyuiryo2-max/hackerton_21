import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/services/memo_promotion_parser.dart';

void main() {
  final now = DateTime(2026, 11, 15, 10); // 2026-11-15는 일요일

  test('매주 일요일 교회를 다음 일요일 반복 일정으로 읽는다', () {
    final draft = MemoPromotionParser.forSchedule('매주 일요일 교회', now: now);

    expect(draft.repeatWeekly, isTrue);
    expect(draft.title, '교회');
    expect(draft.location, '교회');
    expect(draft.start.weekday, DateTime.sunday);
    expect(draft.start.hour, 9);
    expect(draft.start.minute, 0);
    expect(draft.start.isAfter(now), isTrue);
  });

  test('내일 오후 3시 치과 예약을 일정 초안으로 읽는다', () {
    final draft = MemoPromotionParser.forSchedule('내일 오후 3시 치과 예약', now: now);

    expect(draft.repeatWeekly, isFalse);
    expect(draft.title, '치과 예약');
    expect(draft.location, '치과');
    expect(draft.start, DateTime(2026, 11, 16, 15));
  });

  test('할 일의 장소 종류를 미리 골라 둔다', () {
    expect(MemoPromotionParser.todoPlaceType('약 사기'), '약국');
    expect(MemoPromotionParser.todoPlaceType('택배 부치기'), '우체국');
    expect(MemoPromotionParser.todoPlaceType('친구 약속'), isNull);
  });
}
