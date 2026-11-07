import '../models/todo_item.dart';

class TodoRecommendationService {
  List<TodoItem> recommendTodos({
    required List<TodoItem> todos,
    required int availableMinutes,
  }) {
    if (availableMinutes <= 0) {
      return [];
    }

    final recommendations = todos.where((todo) {
      return !todo.isCompleted &&
          !todo.requiresTravel &&
          todo.estimatedMinutes > 0 &&
          todo.estimatedMinutes <= availableMinutes;
    }).toList();

    recommendations.sort(
      (a, b) => a.estimatedMinutes.compareTo(b.estimatedMinutes),
    );

    return recommendations;
  }
}

//완료하지 않은 할 일
//예상 소요 시간이 남는 시간 이하인 할 일
//별도의 장소 이동이 필요하지 않은 할 일
//예상 소요 시간이 짧은 순서로 정렬
