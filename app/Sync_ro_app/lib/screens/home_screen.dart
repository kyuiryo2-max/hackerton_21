
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../models/travel_recommendation.dart';
import '../providers/schedule_controller.dart';
import '../providers/todo_controller.dart';
import '../services/departure_alert_service.dart';
import '../services/recommendation_service.dart';
import '../widgets/recommendation_card.dart';
import 'detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const int _mockTravelMinutes = 35;

  final RecommendationService _recommendationService =
      RecommendationService();

  final DepartureAlertService _departureAlertService =
      DepartureAlertService();

  late Future<List<TravelRecommendation>>
      _recommendationsFuture;

  Timer? _clockTimer;

  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();

    _loadRecommendations();

    _clockTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) {
        if (!mounted) return;

        setState(() {
          _now = DateTime.now();
        });
      },
    );
  }

  void _loadRecommendations() {
    _recommendationsFuture =
        _recommendationService.getRecommendations();
  }

  void _retryRecommendations() {
    setState(() {
      _loadRecommendations();
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _now = DateTime.now();
      _loadRecommendations();
    });

    try {
      await _recommendationsFuture;
    } catch (_) {
      // 오류는 FutureBuilder에서 표시한다.
    }
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _recommendationService.dispose();
    super.dispose();
  }

  String formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');

    return '$hour:$minute';
  }

  String formatDateTime(DateTime time) {
    return '${time.month}/${time.day} ${formatTime(time)}';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year &&
        a.month == b.month &&
        a.day == b.day;
  }

  String _remainingTime(DateTime target) {
    final difference = target.difference(_now);

    if (difference.isNegative ||
        difference == Duration.zero) {
      return '출발 시각이 지났어요';
    }

    final totalMinutes =
        (difference.inSeconds / 60).ceil();

    final hours = totalMinutes ~/ 60;
    final minutes = totalMinutes % 60;

    if (hours > 0) {
      return '$hours시간 $minutes분 남음';
    }

    return '$minutes분 남음';
  }

  void openSchedule(Schedule schedule) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DetailScreen(
          title: schedule.title,
          schedule: schedule,
        ),
      ),
    ).then((_) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
        });
      }
    });
  }

  void openRecommendation(
    TravelRecommendation item,
  ) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text('이동 추천 상세'),
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                item.destination,
                style: Theme.of(context)
                    .textTheme
                    .headlineMedium,
              ),
              const SizedBox(height: 24),
              Text(
                '추천 출발 시간: '
                '${formatTime(item.departureTime)}',
              ),
              Text(
                '예상 도착 시간: '
                '${formatTime(item.arrivalTime)}',
              ),
              Text(
                '예상 이동 시간: '
                '${item.travelMinutes}분',
              ),
              Text(
                '활용 가능 시간: '
                '${item.freeMinutes}분',
              ),
              const SizedBox(height: 24),
              Text(item.suggestion),
              const SizedBox(height: 24),
              const Text(
                '현재는 테스트용 추천 정보입니다.',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNextScheduleCard(
    Schedule? schedule,
  ) {
    if (schedule == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('예정된 일정이 없습니다.'),
        ),
      );
    }

    final departureTime =
        _departureAlertService.calculateDepartureTime(
      schedule.startTime,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Text(
              '다음 일정',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium,
            ),
            const SizedBox(height: 12),

            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.event_available,
                color: Color(0xFF4936D8),
              ),
              title: Text(
                schedule.title,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                ),
              ),
              subtitle: Text(
                '${schedule.location}\n'
                '${formatDateTime(schedule.startTime)} 시작',
              ),
              isThreeLine: true,
              trailing:
                  const Icon(Icons.chevron_right),
              onTap: () => openSchedule(schedule),
            ),

            const Divider(height: 24),

            Row(
              children: [
                Expanded(
                  child: _InfoItem(
                    label: '추천 출발 시간',
                    value: formatTime(departureTime),
                    icon: Icons.schedule,
                  ),
                ),
                const Expanded(
                  child: _InfoItem(
                    label: '예상 이동 시간',
                    value: '$_mockTravelMinutes분',
                    icon: Icons.directions_bus,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            Text(
              _remainingTime(departureTime),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: departureTime.isAfter(_now)
                    ? const Color(0xFF4936D8)
                    : Colors.deepOrange,
              ),
            ),

            const SizedBox(height: 8),

            const Text(
              '임시 계산: 이동 35분 + 여유 10분\n'
              '실제 대중교통 정보는 반영되지 않았습니다.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDepartureAlert(
    Schedule? schedule,
  ) {
    if (schedule == null) {
      return const SizedBox.shrink();
    }

    final alert =
        _departureAlertService.checkDeparture(
      scheduleStart: schedule.startTime,
      now: _now,
    );

    if (alert.status ==
        DepartureAlertStatus.normal) {
      return const SizedBox.shrink();
    }

    final bool isUrgent =
        alert.status ==
            DepartureAlertStatus.leaveNow ||
        alert.status ==
            DepartureAlertStatus.overdue;

    return Card(
      color: isUrgent
          ? const Color(0xFFFFE8E1)
          : const Color(0xFFFFF4D6),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Icon(
              isUrgent
                  ? Icons.warning_amber_rounded
                  : Icons.notifications_active_outlined,
              color: isUrgent
                  ? Colors.deepOrange
                  : Colors.orange.shade800,
            ),
            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    alert.message,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '일정: ${schedule.title}',
                  ),
                  if (alert.status ==
                      DepartureAlertStatus.preparing)
                    Text(
                      '추천 출발까지 '
                      '${alert.remainingMinutes}분 남았습니다.',
                    ),
                  if (alert.status ==
                      DepartureAlertStatus.overdue)
                    const Text(
                      '현재 이동 시간을 다시 확인해 주세요.',
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTodaySchedules(
    List<Schedule> schedules,
  ) {
    if (schedules.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '오늘 등록된 일정이 없습니다.',
          ),
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          for (final schedule in schedules)
            ListTile(
              leading: Icon(
                schedule.isCompleted
                    ? Icons.check_circle
                    : Icons.event_note,
                color: schedule.isCompleted
                    ? Colors.green
                    : const Color(0xFF4936D8),
              ),
              title: Text(
                schedule.title,
                style: TextStyle(
                  decoration: schedule.isCompleted
                      ? TextDecoration.lineThrough
                      : null,
                ),
              ),
              subtitle: Text(
                '${formatTime(schedule.startTime)} · '
                '${schedule.location}',
              ),
              trailing:
                  const Icon(Icons.chevron_right),
              onTap: () => openSchedule(schedule),
            ),
        ],
      ),
    );
  }

  Widget _buildTodos(
    List<TodoItem> todos,
    TodoController controller,
  ) {
    if (todos.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('남은 할 일이 없습니다.'),
        ),
      );
    }

    final visibleTodos =
        todos.take(3).toList();

    return Card(
      child: Column(
        children: [
          for (final todo in visibleTodos)
            CheckboxListTile(
              value: todo.isCompleted,
              onChanged: (checked) async {
                if (checked == null) return;

                await controller.toggleCompleted(
                  todo,
                );
              },
              title: Text(todo.title),
              subtitle: Text(
                '예상 ${todo.estimatedMinutes}분'
                '${todo.requiresTravel ? ' · 이동 필요' : ''}',
              ),
              controlAffinity:
                  ListTileControlAffinity.leading,
              activeColor:
                  const Color(0xFF4936D8),
            ),

          if (todos.length > 3)
            Padding(
              padding: const EdgeInsets.only(
                left: 16,
                right: 16,
                bottom: 12,
              ),
              child: Align(
                alignment:
                    Alignment.centerRight,
                child: Text(
                  '외 ${todos.length - 3}개 남음',
                  style: const TextStyle(
                    color: Colors.grey,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final scheduleController =
        ScheduleScope.of(context);

    final todoController =
        TodoScope.of(context);

    final schedules =
        scheduleController.schedules;

    final todos =
        todoController.todos;

    final upcomingSchedules = schedules
        .where(
          (schedule) =>
              !schedule.isCompleted &&
              schedule.startTime.isAfter(_now),
        )
        .toList()
      ..sort(
        (a, b) =>
            a.startTime.compareTo(b.startTime),
      );

    final Schedule? nextSchedule =
        upcomingSchedules.isNotEmpty
            ? upcomingSchedules.first
            : null;

    final todaySchedules = schedules
        .where(
          (schedule) =>
              _isSameDay(
                schedule.startTime,
                _now,
              ),
        )
        .toList()
      ..sort(
        (a, b) =>
            a.startTime.compareTo(b.startTime),
      );

    final incompleteTodos = todos
        .where(
          (todo) => !todo.isCompleted,
        )
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync_ro'),
        actions: [
          IconButton(
            tooltip: '새로고침',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            onPressed: () {
              ScaffoldMessenger.of(context)
                  .showSnackBar(
                const SnackBar(
                  content: Text(
                    '알림 기능은 개발 예정입니다.',
                  ),
                ),
              );
            },
            icon: const Icon(
              Icons.notifications_outlined,
            ),
          ),
        ],
      ),

      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          key: const PageStorageKey(
            'home-scroll',
          ),
          physics:
              const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '오늘의 이동을 준비해요',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              '일정과 이동 상황을 함께 확인하세요.',
            ),

            const SizedBox(height: 24),

            _buildNextScheduleCard(
              nextSchedule,
            ),

            if (nextSchedule != null) ...[
              const SizedBox(height: 12),
              _buildDepartureAlert(
                nextSchedule,
              ),
            ],

            const SizedBox(height: 24),

            Text(
              '오늘의 일정',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge,
            ),
            const SizedBox(height: 12),

            _buildTodaySchedules(
              todaySchedules,
            ),

            const SizedBox(height: 24),

            Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '남은 할 일',
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge,
                ),
                Text(
                  '${incompleteTodos.length}개',
                  style: const TextStyle(
                    color: Color(0xFF4936D8),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            _buildTodos(
              incompleteTodos,
              todoController,
            ),

            const SizedBox(height: 24),

            Text(
              '추천 이동 정보',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge,
            ),
            const SizedBox(height: 8),

            FutureBuilder<
                List<TravelRecommendation>>(
              future: _recommendationsFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState ==
                    ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child:
                          CircularProgressIndicator(),
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return Card(
                    child: Padding(
                      padding:
                          const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          const Text(
                            '추천 정보를 불러오지 못했습니다.',
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton(
                            onPressed:
                                _retryRecommendations,
                            child:
                                const Text('다시 시도'),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                final recommendations =
                    snapshot.data ?? [];

                if (recommendations.isEmpty) {
                  return const Card(
                    child: Padding(
                      padding:
                          EdgeInsets.all(16),
                      child: Text(
                        '현재 추천할 이동 정보가 없습니다.',
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    for (final item
                        in recommendations)
                      RecommendationCard(
                        recommendation: item,
                        onTap: () {
                          openRecommendation(
                            item,
                          );
                        },
                      ),
                  ],
                );
              },
            ),

            const SizedBox(height: 24),

            Text(
              '서비스 안내',
              style: Theme.of(context)
                  .textTheme
                  .titleLarge,
            ),
            const SizedBox(height: 12),

            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Sync_ro는 사용자의 일정과 이동 시간을 '
                  '함께 고려해 출발 시점과 '
                  '시간 활용 방법을 추천하는 서비스입니다.',
                ),
              ),
            ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _InfoItem({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: const Color(0xFF4936D8),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.grey,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          value,
          style: Theme.of(context)
              .textTheme
              .titleLarge,
        ),
      ],
    );
  }
}
