import 'package:flutter_test/flutter_test.dart';
import 'package:sync_ro_app/models/todo_item.dart';

void main() {
  test('장소 종류가 있으면 들를 곳이 있는 할 일이에요', () {
    const todo = TodoItem(
      id: 1,
      title: '약 사기',
      estimatedMinutes: 5,
      placeTypes: ['약국'],
    );

    expect(todo.hasStopover, isTrue);
  });

  test('고른 가게 이름이 있으면 들를 곳이 있는 할 일이에요', () {
    const todo = TodoItem(
      id: 1,
      title: '약 사기',
      estimatedMinutes: 5,
      placeName: 'CU 안암센트럴점',
    );

    expect(todo.hasStopover, isTrue);
  });

  test('장소 정보가 없으면 들를 곳이 없는 할 일이에요', () {
    const todo = TodoItem(id: 1, title: '전화하기', estimatedMinutes: 5);

    expect(todo.hasStopover, isFalse);
  });

  test('로컬 저장 JSON에도 가게 이름이 남아요', () {
    const todo = TodoItem(
      id: 1,
      title: '약 사기',
      estimatedMinutes: 5,
      placeName: 'CU 안암센트럴점',
      placeTypes: ['약국'],
    );

    final restored = TodoItem.fromJson(todo.toJson());

    expect(restored.placeName, 'CU 안암센트럴점');
    expect(restored.placeTypes, ['약국']);
    expect(restored.hasStopover, isTrue);
  });
}
