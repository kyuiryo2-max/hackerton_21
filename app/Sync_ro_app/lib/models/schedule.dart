class Schedule {
  final int id;
  final String title;
  final String location;
  final String? destinationPlaceId;
  final String? destinationAddress;
  final double? destinationLatitude;
  final double? destinationLongitude;
  final DateTime startTime;
  final DateTime endTime;
  final bool isCompleted;
  final int preparationMinutes;

  const Schedule({
    required this.id,
    required this.title,
    required this.location,
    this.destinationPlaceId,
    this.destinationAddress,
    this.destinationLatitude,
    this.destinationLongitude,
    required this.startTime,
    required this.endTime,
    this.isCompleted = false,
    this.preparationMinutes = 30,
  });

  Schedule copyWith({
    String? title,
    String? location,
    String? destinationPlaceId,
    String? destinationAddress,
    double? destinationLatitude,
    double? destinationLongitude,
    DateTime? startTime,
    DateTime? endTime,
    bool? isCompleted,
    int? preparationMinutes,
  }) {
    return Schedule(
      id: id,
      title: title ?? this.title,
      location: location ?? this.location,
      destinationPlaceId: destinationPlaceId ?? this.destinationPlaceId,
      destinationAddress: destinationAddress ?? this.destinationAddress,
      destinationLatitude: destinationLatitude ?? this.destinationLatitude,
      destinationLongitude: destinationLongitude ?? this.destinationLongitude,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      isCompleted: isCompleted ?? this.isCompleted,
      preparationMinutes: preparationMinutes ?? this.preparationMinutes,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'location': location,
    'destination_place_id': destinationPlaceId,
    'destination_address': destinationAddress,
    'destination_latitude': destinationLatitude,
    'destination_longitude': destinationLongitude,
    'start_time': startTime.toIso8601String(),
    'end_time': endTime.toIso8601String(),
    'is_completed': isCompleted,
    'preparation_minutes': preparationMinutes,
  };

  factory Schedule.fromJson(Map<String, dynamic> json) {
    return Schedule(
      id: (json['id'] as num).toInt(),
      title: json['title'] as String,
      location: json['location'] as String,
      destinationPlaceId: json['destination_place_id'] as String?,
      destinationAddress: json['destination_address'] as String?,
      destinationLatitude: (json['destination_latitude'] as num?)?.toDouble(),
      destinationLongitude: (json['destination_longitude'] as num?)?.toDouble(),
      startTime: DateTime.parse(json['start_time'] as String),
      endTime: DateTime.parse(json['end_time'] as String),
      isCompleted: json['is_completed'] as bool? ?? false,
      preparationMinutes: (json['preparation_minutes'] as num?)?.toInt() ?? 30,
    );
  }
}
