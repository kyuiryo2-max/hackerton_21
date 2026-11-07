
class Schedule {
  final int id;
  final String title;
  final String location;
  final DateTime startTime;
  final DateTime endTime;
  final bool isCompleted;

  const Schedule({
    required this.id,
    required this.title,
    required this.location,
    required this.startTime,
    required this.endTime,
    this.isCompleted = false,
  });

  Schedule copyWith({
    String? title,
    String? location,
    DateTime? startTime,
    DateTime? endTime,
    bool? isCompleted,
  }) {
    return Schedule(
      id: id,
      title: title ?? this.title,
      location: location ?? this.location,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'location': location,
    'start_time': startTime.toIso8601String(),
    'end_time': endTime.toIso8601String(),
    'is_completed': isCompleted,
  };

  factory Schedule.fromJson(Map<String, dynamic> json) {
    return Schedule(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String,
      location: json['location'] as String,
      startTime: DateTime.parse(json['start_time'] as String),
      endTime: DateTime.parse(json['end_time'] as String),
      isCompleted: json['is_completed'] as bool? ?? false,
    );
  }
}
