class Schedule {
  final int id;
  final String title;
  final String location;
  final String? destinationPlaceId;
  final String? destinationAddress;
  final double? destinationLatitude;
  final double? destinationLongitude;
  /// current: use device location when planning; place: stored selected place.
  final String originMode;
  final String? originPlaceId;
  final String? originName;
  final String? originAddress;
  final double? originLatitude;
  final double? originLongitude;
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
    this.originMode = 'current',
    this.originPlaceId,
    this.originName,
    this.originAddress,
    this.originLatitude,
    this.originLongitude,
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
    String? originMode,
    bool clearOrigin = false,
    String? originPlaceId,
    String? originName,
    String? originAddress,
    double? originLatitude,
    double? originLongitude,
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
      originMode: originMode ?? this.originMode,
      originPlaceId: clearOrigin ? null : (originPlaceId ?? this.originPlaceId),
      originName: clearOrigin ? null : (originName ?? this.originName),
      originAddress: clearOrigin ? null : (originAddress ?? this.originAddress),
      originLatitude: clearOrigin ? null : (originLatitude ?? this.originLatitude),
      originLongitude: clearOrigin ? null : (originLongitude ?? this.originLongitude),
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
    'origin_mode': originMode,
    'origin_place_id': originMode == 'place' ? originPlaceId : null,
    'origin_name': originMode == 'place' ? originName : null,
    'origin_address': originMode == 'place' ? originAddress : null,
    'origin_latitude': originMode == 'place' ? originLatitude : null,
    'origin_longitude': originMode == 'place' ? originLongitude : null,
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
      originMode: json['origin_mode'] == 'place' ? 'place' : 'current',
      originPlaceId: json['origin_place_id'] as String?,
      originName: json['origin_name'] as String?,
      originAddress: json['origin_address'] as String?,
      originLatitude: (json['origin_latitude'] as num?)?.toDouble(),
      originLongitude: (json['origin_longitude'] as num?)?.toDouble(),
      startTime: DateTime.parse(json['start_time'] as String),
      endTime: DateTime.parse(json['end_time'] as String),
      isCompleted: json['is_completed'] as bool? ?? false,
      preparationMinutes: (json['preparation_minutes'] as num?)?.toInt() ?? 30,
    );
  }
}
