import '../models/todo_item.dart';

/// 시연 모드 할 일 (11/21). 발표 시연 계획(presentation_demo_data.dart)의 todo_id·장소 종류와 같아요.
/// AI 분류 없이도 장소 종류가 붙어 있어서, 할 일 탭과 이동 탭의 [할 일 적용하기]가 같은 할 일을 보여 줘요.
const List<TodoItem> mockTodos = [
  TodoItem(
    id: 1,
    title: '이어폰 사기',
    estimatedMinutes: 4,
    requiresTravel: true,
    placeTypes: ['편의점', '다이소', '마트'],
    important: true,
  ),
  TodoItem(
    id: 2,
    title: '커피 사기',
    estimatedMinutes: 5,
    requiresTravel: true,
    placeTypes: ['카페', '편의점'],
  ),
  TodoItem(
    id: 3,
    title: '다이소 들르기',
    estimatedMinutes: 5,
    requiresTravel: true,
    placeTypes: ['다이소'],
    important: true,
  ),
];
