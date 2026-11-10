import 'package:flutter/material.dart';

import '../models/schedule.dart';


class DetailScreen extends StatelessWidget {
  final String title;
  final Schedule? schedule;
  final ValueChanged<Schedule>? onOpenScheduleRoutes;

  const DetailScreen({super.key, required this.title, this.schedule, this.onOpenScheduleRoutes});

  String _formatDateTime(DateTime value) {
    final year = value.year;
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');

    return '$year-$month-$day $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),

          const SizedBox(height: 20),

          if (schedule != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('일정 장소'),
                    const SizedBox(height: 6),
                    Text(
                      schedule!.location,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),

                    const Divider(height: 32),

                    const Text('시작 시간'),
                    const SizedBox(height: 6),
                    Text(_formatDateTime(schedule!.startTime)),

                    const SizedBox(height: 16),

                    const Text('종료 시간'),
                    const SizedBox(height: 6),
                    Text(_formatDateTime(schedule!.endTime)),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),

            FilledButton.icon(
              onPressed: onOpenScheduleRoutes == null ? null : () {
                final target = schedule!;
                // Return to the existing tab navigator rather than stacking a
                // second NavigationScreen with no bottom navigation bar.
                Navigator.of(context).pop();
                onOpenScheduleRoutes!(target);
              },
              icon: const Icon(Icons.route),
              label: const Text('이 일정으로 이동 추천'),
            ),
          ] else
            const Text('상세 정보를 확인하는 화면입니다.'),
        ],
      ),
    );
  }
}
