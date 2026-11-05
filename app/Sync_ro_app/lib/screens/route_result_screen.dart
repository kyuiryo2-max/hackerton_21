
import 'package:flutter/material.dart';

import '../models/route_candidate.dart';
import '../models/route_request.dart';
import '../models/travel_recommendation.dart';
import '../providers/todo_controller.dart';
import '../services/todo_recommendation_service.dart';
import '../widgets/route_candidate_card.dart';
import '../widgets/todo_card.dart';

class RouteResultScreen extends StatelessWidget {
  final RouteRequest request;
  final TravelRecommendation recommendation;

  const RouteResultScreen({
    super.key,
    required this.request,
    required this.recommendation,
  });

  List<RouteCandidate> _mockCandidates() {
    return const [
      RouteCandidate(
        id: 'route_1',
        title: '도보 + 버스',
        isRecommended: true,
        transferCount: 0,
        segments: [
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '가까운 버스 정류장까지 이동',
            durationMinutes: 8,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '버스 탑승 대기',
            durationMinutes: 4,
          ),
          RouteSegment(
            type: RouteSegmentType.bus,
            description: '버스 탑승',
            durationMinutes: 25,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '정류장에서 목적지까지 이동',
            durationMinutes: 5,
          ),
        ],
      ),
      RouteCandidate(
        id: 'route_2',
        title: '도보 + 지하철',
        transferCount: 0,
        segments: [
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '지하철역까지 이동',
            durationMinutes: 12,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '열차 탑승 대기',
            durationMinutes: 5,
          ),
          RouteSegment(
            type: RouteSegmentType.subway,
            description: '지하철 탑승',
            durationMinutes: 22,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '역에서 목적지까지 이동',
            durationMinutes: 7,
          ),
        ],
      ),
      RouteCandidate(
        id: 'route_3',
        title: '도보 + 버스 + 지하철',
        transferCount: 1,
        segments: [
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '버스 정류장까지 이동',
            durationMinutes: 5,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '버스 탑승 대기',
            durationMinutes: 3,
          ),
          RouteSegment(
            type: RouteSegmentType.bus,
            description: '버스 탑승',
            durationMinutes: 12,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '환승역까지 이동',
            durationMinutes: 4,
          ),
          RouteSegment(
            type: RouteSegmentType.waiting,
            description: '지하철 탑승 대기',
            durationMinutes: 4,
          ),
          RouteSegment(
            type: RouteSegmentType.subway,
            description: '지하철 탑승',
            durationMinutes: 15,
          ),
          RouteSegment(
            type: RouteSegmentType.walking,
            description: '목적지까지 이동',
            durationMinutes: 4,
          ),
        ],
      ),
    ];
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final todoController = TodoScope.of(context);

    final todoService = TodoRecommendationService();

    final recommendedTodos = todoService.recommendTodos(
      todos: todoController.todos,
      availableMinutes: recommendation.freeMinutes,
    );

    final candidates = _mockCandidates();

    return Scaffold(
      appBar: AppBar(
        title: const Text('이동 추천 결과'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '${request.origin} → ${request.destination}',
            style: Theme.of(context).textTheme.titleLarge,
          ),

          const SizedBox(height: 12),

          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('기존 이동 시간 계산 결과'),
                  const SizedBox(height: 12),
                  Text(
                    '추천 출발: '
                    '${_formatTime(recommendation.departureTime)}',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '예상 도착: '
                    '${_formatTime(recommendation.arrivalTime)}',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '남는 시간: ${recommendation.freeMinutes}분',
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          Text(
            '경로 후보 비교',
            style: Theme.of(context).textTheme.titleLarge,
          ),

          const SizedBox(height: 8),

          const Text(
            '아래 경로와 소요 시간은 화면 개발용 '
            '가상 데이터이며 실제 이동 경로가 아닙니다.',
            style: TextStyle(color: Colors.grey),
          ),

          const SizedBox(height: 16),

          ...candidates.map(
            (candidate) => RouteCandidateCard(
              candidate: candidate,
            ),
          ),

          const SizedBox(height: 24),

          Text(
            '남는 시간에 할 수 있는 일',
            style: Theme.of(context).textTheme.titleLarge,
          ),

          const SizedBox(height: 12),

          if (recommendedTodos.isEmpty)
            const Text(
              '현재 남는 시간에 추천할 할 일이 없습니다.',
            )
          else
            ...recommendedTodos.map(
              (todo) => TodoCard(
                todo: todo,
              ),
            ),

          const SizedBox(height: 24),

          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('이동 계획 다시 설정하기'),
          ),
        ],
      ),
    );
  }
}
