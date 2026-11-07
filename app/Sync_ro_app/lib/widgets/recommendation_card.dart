import 'package:flutter/material.dart';
import '../models/travel_recommendation.dart';

class RecommendationCard extends StatelessWidget {
  final TravelRecommendation recommendation;
  final VoidCallback onTap;

  const RecommendationCard({
    super.key,
    required this.recommendation,
    required this.onTap,
  });

  String formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final item = recommendation;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.destination,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),

              Text('추천 출발: ${formatTime(item.departureTime)}'),
              Text('예상 도착: ${formatTime(item.arrivalTime)}'),
              Text('이동 시간: ${item.travelMinutes}분'),

              const Divider(height: 24),

              Row(
                children: [
                  const Icon(Icons.lightbulb_outline),
                  const SizedBox(width: 8),
                  Expanded(child: Text(item.suggestion)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
