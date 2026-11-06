import 'package:flutter/material.dart';
import 'route_map_screen.dart';
import '../models/route_request.dart';
import '../models/travel_recommendation.dart';
import '../models/route_candidate.dart';
import '../models/route_plan.dart';
import '../services/route_planning_service.dart';
import '../services/todo_recommendation_service.dart';
import '../providers/todo_controller.dart';
import '../widgets/route_candidate_card.dart';
import '../widgets/todo_card.dart';
import '../services/route_api_service.dart';

class RouteResultScreen extends StatefulWidget {
  final RouteRequest request;
  final TravelRecommendation recommendation;

  const RouteResultScreen({
    super.key,
    required this.request,
    required this.recommendation,
  });

  @override
  State<RouteResultScreen> createState() => _RouteResultScreenState();
}

class _RouteResultScreenState extends State<RouteResultScreen> {
  String? _selectedRouteId;

  // 임시 경로 후보 데이터
  // 추후 실제 대중교통 API 응답으로 교체 예정

  final RouteApiService _routeApiService = RouteApiService();

  List<RouteCandidate> _candidates = [];

  bool _isLoadingRoutes = true;
  String? _routeError;

  @override
  void initState() {
    super.initState();
    _loadRoutes();
  }

  Future<void> _loadRoutes() async {
    setState(() {
      _isLoadingRoutes = true;
      _routeError = null;
    });

    try {
      final routes = await _routeApiService.searchRoutes(widget.request);

      if (!mounted) return;

      setState(() {
        _candidates = routes;
        _selectedRouteId = null;
        _isLoadingRoutes = false;
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _routeError = error.toString();
        _isLoadingRoutes = false;
      });
    }
  }

  String _formatDateTime(DateTime dateTime) {
    final year = dateTime.year;
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');

    return '$year-$month-$day $hour:$minute';
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingRoutes) {
      return Scaffold(
        appBar: AppBar(title: const Text('이동 경로 추천 결과')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_routeError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('이동 경로 추천 결과')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48),
                const SizedBox(height: 12),
                Text(_routeError!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _loadRoutes,
                  child: const Text('다시 검색'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_candidates.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('이동 경로 추천 결과')),
        body: const Center(child: Text('검색된 이동 경로가 없습니다.')),
      );
    }
    final todoController = TodoScope.of(context);
    final todoService = TodoRecommendationService();

    final candidates = _candidates;

    final selectedCandidate = candidates.firstWhere(
      (candidate) => candidate.id == (_selectedRouteId ?? candidates.first.id),
      orElse: () => candidates.first,
    );

    final RoutePlan plan = RoutePlanningService().createPlan(
      candidate: selectedCandidate,
      desiredArrivalTime: widget.request.desiredArrivalTime,
    );

    final availableMinutes = plan.freeMinutes > 0 ? plan.freeMinutes : 0;

    final recommendedTodos = todoService.recommendTodos(
      todos: todoController.todos,
      availableMinutes: availableMinutes,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('이동 경로 추천 결과')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 출발지 / 목적지
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '이동 정보',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  _buildInfoRow('출발지', widget.request.origin),
                  _buildInfoRow('목적지', widget.request.destination),
                  _buildInfoRow(
                    '도착 희망 시간',
                    _formatDateTime(widget.request.desiredArrivalTime),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          const Text(
            '추천 경로 후보',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          const Text(
            '현재는 Mock 데이터로 경로를 표시합니다. '
            '실제 출발지와 목적지에 따른 경로 탐색은 '
            '추후 API 연동 시 적용됩니다.',
            style: TextStyle(color: Colors.grey, fontSize: 13),
          ),

          const SizedBox(height: 12),

          // 경로 후보 선택
          ...candidates.map((candidate) {
            final isSelected = candidate.id == selectedCandidate.id;

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  setState(() {
                    _selectedRouteId = candidate.id;
                  });
                },
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: isSelected
                          ? Theme.of(context).colorScheme.primary
                          : Colors.transparent,
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      if (isSelected)
                        Padding(
                          padding: const EdgeInsets.only(
                            top: 8,
                            left: 12,
                            right: 12,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.check_circle,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                '선택한 경로',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      RouteCandidateCard(candidate: candidate),
                    ],
                  ),
                ),
              ),
            );
          }),

          const SizedBox(height: 12),

          OutlinedButton.icon(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => RouteMapScreen(
                    origin: widget.request.origin,
                    destination: widget.request.destination,
                    originPlace: widget.request.originPlace,
                    destinationPlace: widget.request.destinationPlace,
                    candidate: selectedCandidate,
                  ),
                ),
              );
            },
            icon: const Icon(Icons.map_outlined),
            label: const Text('선택한 경로 상세 보기'),
          ),

          const SizedBox(height: 20),

          // 선택한 경로 기준 시간 계산
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '선택한 경로의 이동 계획',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),

                  _buildInfoRow('선택 경로', selectedCandidate.title),
                  _buildInfoRow(
                    '총 이동 시간',
                    '${selectedCandidate.totalMinutes}분',
                  ),
                  _buildInfoRow(
                    '도보 시간',
                    '${selectedCandidate.walkingMinutes}분',
                  ),
                  _buildInfoRow(
                    '대기 시간',
                    '${selectedCandidate.waitingMinutes}분',
                  ),
                  _buildInfoRow('환승 횟수', '${selectedCandidate.transferCount}회'),
                  _buildInfoRow('출발 여유 시간', '${plan.bufferMinutes}분'),

                  const Divider(height: 24),

                  _buildInfoRow(
                    '추천 출발 시간',
                    _formatDateTime(plan.departureTime),
                  ),
                  _buildInfoRow(
                    '예상 도착 시간',
                    _formatDateTime(plan.estimatedArrivalTime),
                  ),
                  _buildInfoRow('출발 전 남는 시간', '$availableMinutes분'),

                  if (!plan.canLeaveOnTime) ...[
                    const SizedBox(height: 12),
                    const Text(
                      '권장 출발 시간이 지났습니다. '
                      '다른 경로나 도착 시간을 확인하세요.',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // 남는 시간에 수행할 할 일 추천
          const Text(
            '남는 시간에 할 수 있는 일',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          if (availableMinutes <= 0)
            const Text('출발 전 여유 시간이 없습니다.')
          else if (recommendedTodos.isEmpty)
            const Text('현재 남는 시간에 수행할 수 있는 할 일이 없습니다.')
          else
            ...recommendedTodos.map(
              (todo) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TodoCard(todo: todo),
              ),
            ),

          const SizedBox(height: 24),

          FilledButton(
            onPressed: () {
              Navigator.pop(context);
            },
            child: const Text('다시 경로 검색하기'),
          ),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
