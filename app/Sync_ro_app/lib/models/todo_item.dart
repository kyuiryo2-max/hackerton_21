

class TodoItem {
  final int id;
  final String title;
  final int estimatedMinutes;
  final bool requiresTravel;
  final bool isCompleted;

  const TodoItem({
    required this.id,
    required this.title,
    required this.estimatedMinutes,
    this.requiresTravel = false,
    this.isCompleted = false,
  });

  TodoItem copyWith({
    String? title,
    int? estimatedMinutes,
    bool? requiresTravel,
    bool? isCompleted,
  }) {
    return TodoItem(
      id: id,
      title: title ?? this.title,
      estimatedMinutes:
          estimatedMinutes ?? this.estimatedMinutes,
      requiresTravel: requiresTravel ?? this.requiresTravel,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'estimated_minutes': estimatedMinutes,
        'requires_travel': requiresTravel,
        'is_completed': isCompleted,
      };

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    return TodoItem(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String,
      estimatedMinutes:
          (json['estimated_minutes'] as num).toInt(),
      requiresTravel: json['requires_travel'] as bool? ?? false,
      isCompleted: json['is_completed'] as bool? ?? false,
    );
  }
}

//나중에는 장소 좌표, 운영시간, 우선순위 등의 속성도 추가할 수 있어.