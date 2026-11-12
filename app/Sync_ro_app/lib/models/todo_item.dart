class TodoItem {
  final int id;
  final String title;
  final int estimatedMinutes;
  final bool requiresTravel;
  final bool isCompleted;
  final String? placeName;

  /// AI가 붙인 장소 종류 (예: 편의점, 다이소). 여러 개면 그중 한 곳에 들르면 돼요 (11/13).
  final List<String> placeTypes;

  /// "꼭" 할 일 (서버 importance 필수). 시간이 부족해도 빼지 않고 물어봐요.
  final bool important;

  /// [estimatedMinutes]는 그곳에 머무는 시간(서버 stay_minutes)이에요.
  const TodoItem({
    required this.id,
    required this.title,
    required this.estimatedMinutes,
    this.requiresTravel = false,
    this.isCompleted = false,
    this.placeName,
    this.placeTypes = const [],
    this.important = false,
  });

  TodoItem copyWith({
    String? title,
    int? estimatedMinutes,
    bool? requiresTravel,
    bool? isCompleted,
    String? placeName,
    List<String>? placeTypes,
    bool? important,
  }) {
    return TodoItem(
      id: id,
      title: title ?? this.title,
      estimatedMinutes: estimatedMinutes ?? this.estimatedMinutes,
      requiresTravel: requiresTravel ?? this.requiresTravel,
      isCompleted: isCompleted ?? this.isCompleted,
      placeName: placeName ?? this.placeName,
      placeTypes: placeTypes ?? this.placeTypes,
      important: important ?? this.important,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'estimated_minutes': estimatedMinutes,
    'requires_travel': requiresTravel,
    'is_completed': isCompleted,
    'place_name': placeName,
    'place_types': placeTypes,
    'important': important,
  };

  factory TodoItem.fromJson(Map<String, dynamic> json) {
    return TodoItem(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String,
      estimatedMinutes: (json['estimated_minutes'] as num).toInt(),
      requiresTravel: json['requires_travel'] as bool? ?? false,
      isCompleted: json['is_completed'] as bool? ?? false,
      placeName: json['place_name'] as String?,
      placeTypes: (json['place_types'] as List?)?.whereType<String>().toList() ?? const [],
      important: json['important'] as bool? ?? false,
    );
  }
}

//나중에는 장소 좌표, 운영시간, 우선순위 등의 속성도 추가할 수 있어.
