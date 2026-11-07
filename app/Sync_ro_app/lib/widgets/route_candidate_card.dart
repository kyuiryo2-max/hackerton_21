
import 'package:flutter/material.dart';

import '../models/route_candidate.dart';

class RouteCandidateCard extends StatelessWidget {
  final RouteCandidate candidate;

  const RouteCandidateCard({
    super.key,
    required this.candidate,
  });

  IconData _iconFor(RouteSegmentType type) {
    switch (type) {
      case RouteSegmentType.walking:
        return Icons.directions_walk;
      case RouteSegmentType.bus:
        return Icons.directions_bus;
      case RouteSegmentType.subway:
        return Icons.train;
      case RouteSegmentType.waiting:
        return Icons.schedule;
    }
  }

  String _labelFor(RouteSegmentType type) {
    switch (type) {
      case RouteSegmentType.walking:
        return '도보';
      case RouteSegmentType.bus:
        return '버스';
      case RouteSegmentType.subway:
        return '지하철';
      case RouteSegmentType.waiting:
        return '대기';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    candidate.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium,
                  ),
                ),
                if (candidate.isRecommended)
                  const Chip(
                    label: Text('추천 경로'),
                  ),
              ],
            ),

            const SizedBox(height: 8),

            Text(
              '총 ${candidate.totalMinutes}분',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall,
            ),

            const SizedBox(height: 12),

            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  avatar: const Icon(
                    Icons.directions_walk,
                    size: 18,
                  ),
                  label: Text(
                    '도보 ${candidate.walkingMinutes}분',
                  ),
                ),
                Chip(
                  avatar: const Icon(
                    Icons.schedule,
                    size: 18,
                  ),
                  label: Text(
                    '대기 ${candidate.waitingMinutes}분',
                  ),
                ),
                Chip(
                  label: Text(
                    '환승 ${candidate.transferCount}회',
                  ),
                ),
              ],
            ),

            const Divider(height: 28),

            ...candidate.segments.map(
              (segment) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _iconFor(segment.type),
                ),
                title: Text(segment.description),
                subtitle: Text(
                  _labelFor(segment.type),
                ),
                trailing: Text(
                  '${segment.durationMinutes}분',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
