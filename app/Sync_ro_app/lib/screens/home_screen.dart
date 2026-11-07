
import 'package:flutter/material.dart';
import '../providers/schedule_controller.dart';
import '../services/recommendation_service.dart';
import '../models/schedule.dart';
import '../models/travel_recommendation.dart';
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
  
final RecommendationService _recommendationService =
    RecommendationService();

late Future<List<TravelRecommendation>>
    _recommendationsFuture;

@override
void initState() {
  super.initState();
  _loadRecommendations();
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

@override
void dispose() {
  _recommendationService.dispose();
  super.dispose();
}


  String formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
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
    );
  }

  void openRecommendation(TravelRecommendation item) {
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheduleController = ScheduleScope.of(context);

    final now = DateTime.now();

    final upcomingSchedules = scheduleController.schedules
      .where(
        (schedule) =>
            !schedule.isCompleted &&
            schedule.startTime.isAfter(now),
      )
      .toList();

    upcomingSchedules.sort(
      (a, b) => a.startTime.compareTo(b.startTime),
    );

    final Schedule? nextSchedule =
        upcomingSchedules.isNotEmpty
            ? upcomingSchedules.first
            : null;
    

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync_ro'),
        actions: [
          IconButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('알림 기능은 개발 예정입니다.'),
                ),
              );
            },
            icon: const Icon(
              Icons.notifications_outlined,
            ),
          ),
        ],
      ),
      body: ListView(
        key: const PageStorageKey('home-scroll'),
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

          Text(
            '다음 일정',
            style: Theme.of(context)
                .textTheme
                .titleLarge,
          ),
          const SizedBox(height: 12),

          if (nextSchedule != null)
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.event_available,
                ),
                title: Text(nextSchedule.title),
                subtitle: Text(
                  '${nextSchedule.location}\n'
                  '${formatTime(nextSchedule.startTime)} 시작',
                ),
                isThreeLine: true,
                trailing: const Icon(
                  Icons.chevron_right,
                ),
                onTap: () {
                  openSchedule(nextSchedule);
                },
              ),
            )
          else
            const Text('등록된 일정이 없습니다.'),

          const SizedBox(height: 24),

          Text(
            '추천 이동 정보',
            style: Theme.of(context)
                .textTheme
                .titleLarge,
          ),
          const SizedBox(height: 8),

          
FutureBuilder<List<TravelRecommendation>>(
  future: _recommendationsFuture,
  builder: (context, snapshot) {
    if (snapshot.connectionState ==
        ConnectionState.waiting) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (snapshot.hasError) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              const Text(
                '추천 정보를 불러오지 못했습니다.',
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _retryRecommendations,
                child: const Text('다시 시도'),
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
          padding: EdgeInsets.all(16),
          child: Text(
            '현재 추천할 이동 정보가 없습니다.',
          ),
        ),
      );
    }

    return Column(
      children: [
        for (final item in recommendations)
          RecommendationCard(
            recommendation: item,
            onTap: () {
              openRecommendation(item);
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
        ],
      ),
    );
  }
}
