
import '../models/todo_item.dart';

const List<TodoItem> mockTodos = [
  TodoItem(
    id: 1,
    title: '이메일 확인 및 답장',
    estimatedMinutes: 15,
  ),
  TodoItem(
    id: 2,
    title: '편의점에서 물품 구매',
    estimatedMinutes: 10,
    requiresTravel: true,
  ),
  TodoItem(
    id: 3,
    title: '팀 프로젝트 자료 정리',
    estimatedMinutes: 25,
  ),
  TodoItem(
    id: 4,
    title: '약국에서 물품 구매',
    estimatedMinutes: 20,
    requiresTravel: true,
  ),
  TodoItem(
    id: 5,
    title: '강의 자료 확인',
    estimatedMinutes: 10,
  ),
];
//임시 할 일 데이터