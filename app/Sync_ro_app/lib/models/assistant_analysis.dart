class AssistantAnalysis {
  final String intent;
  final String? destination;
  final String? arrivalTime;
  final String? todoDescription;
  final String? placeCategory;
  final int? estimatedMinutes;
  final bool needsClarification;
  final String? clarificationQuestion;
  final String provider;

  AssistantAnalysis.fromJson(Map<String, dynamic> json, this.provider)
      : intent = json['intent']?.toString() ?? 'other',
        destination = json['destination'] as String?,
        arrivalTime = json['arrival_time'] as String?,
        todoDescription = (json['todo'] is Map) ? json['todo']['description'] as String? : null,
        placeCategory = (json['todo'] is Map) ? json['todo']['place_category'] as String? : null,
        estimatedMinutes = (json['todo'] is Map) ? json['todo']['estimated_minutes'] as int? : null,
        needsClarification = json['needs_clarification'] == true,
        clarificationQuestion = json['clarification_question'] as String?;
}
