
import 'dart:async';

import 'package:flutter/material.dart';

import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../providers/schedule_controller.dart';
import '../providers/todo_controller.dart';
import '../services/departure_alert_service.dart';
import '../services/todo_recommendation_service.dart';
import 'detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.onOpenRoutes, required this.onSelectWaypoint});

  final VoidCallback onOpenRoutes;
  final ValueChanged<TodoItem> onSelectWaypoint;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const int _mockTravelMinutes = 35;

  final TodoRecommendationService _todoRecommendationService = TodoRecommendationService();

  final DepartureAlertService _departureAlertService =
      DepartureAlertService();

  Timer? _clockTimer;

  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();

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

  Future<void> _refresh() async {
    setState(() {
      _now = DateTime.now();
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
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

  Widget _buildPreparationCard(Schedule? schedule, List<TodoItem> todos) {
    if (schedule == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('다가오는 일정이 없습니다. 일정을 추가해 주세요.'),
        ),
      );
    }

    final departure = _departureAlertService.calculateDepartureTime(
      schedule.startTime,
    );
    final preparation = departure.subtract(
      Duration(minutes: schedule.preparationMinutes),
    );
    final theme = Theme.of(context);
    // 준비 시작 전까지 남은 시간에 처리 가능한, 별도 이동이 없는 할 일만 추천한다.
    final availableMinutes = preparation.difference(_now).inMinutes;
    final suggested = _todoRecommendationService.recommendTodos(
      todos: todos,
      availableMinutes: availableMinutes,
    );

    Widget timeColumn(String label, DateTime time) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            formatTime(time),
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.bold,
              color: const Color(0xFF4936D8),
            ),
          ),
          Text(formatDateTime(time), style: theme.textTheme.bodySmall),
        ],
      ),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('오늘의 준비 · 출발', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(schedule.title, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            Row(
              children: [
                timeColumn('준비 시작', preparation),
                const SizedBox(width: 12),
                timeColumn('출발 시각', departure),
              ],
            ),
            const SizedBox(height: 12),
            const SizedBox(height: 8),
            Text(
              '목표 도착 ${formatDateTime(schedule.startTime)} · 예상 이동 35분 · 여유 10분 · 준비 ${schedule.preparationMinutes}분 (임시 기준)',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 28),
            Text('준비 전 추천 할 일', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            if (suggested.isEmpty)
              const Text('현재 남는 시간에 맞는 할 일이 없습니다.'),
            for (final todo in suggested.take(2))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_outline),
                title: Text(todo.title),
                subtitle: Text('예상 ${todo.estimatedMinutes}분 · 별도 이동 없음'),
              ),
            // 장소 이름이 있는 이동 필요 할 일을 경유 후보로 제안한다.
            if (todos.any((todo) => !todo.isCompleted && todo.requiresTravel &&
                (todo.placeName?.trim().isNotEmpty ?? false))) ...[
              const Divider(height: 28),
              Text('경유 후보 할 일', style: theme.textTheme.titleMedium),
              const Text('선택하면 이동 화면으로 넘어갑니다. 경유 경로 계산은 아직 지원하지 않습니다.'),
              for (final todo in todos.where((todo) => !todo.isCompleted &&
                  todo.requiresTravel && (todo.placeName?.trim().isNotEmpty ?? false)).take(2))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.add_location_alt_outlined),
                  title: Text(todo.title),
                  subtitle: Text('${todo.placeName ?? '장소 미지정'} · 체류 ${todo.estimatedMinutes}분'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        title: const Text('경유지 선택'),
                        content: Text('${todo.placeName ?? todo.title}을(를) 경유 후보로 선택할까요?\n현재는 경로를 자동 재계산하지 않습니다.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('취소')),
                          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('선택')),
                        ],
                      ),
                    );
                    if (confirmed == true && mounted) widget.onSelectWaypoint(todo);
                  },
                ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.onOpenRoutes,
                icon: const Icon(Icons.route),
                label: const Text('추천 경로 확인하기'),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '이동 탭에서 출발지를 선택하면 경로를 검색할 수 있습니다.',
              style: theme.textTheme.bodySmall,
            ),
          ],
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

            const SizedBox(height: 16),
            _buildPreparationCard(nextSchedule, incompleteTodos),
            const SizedBox(height: 16),

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
