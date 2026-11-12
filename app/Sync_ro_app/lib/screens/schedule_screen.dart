import 'package:flutter/material.dart';

import '../models/schedule.dart';
import '../providers/schedule_controller.dart';
import 'schedule_form_screen.dart';
import 'detail_screen.dart';

class ScheduleScreen extends StatelessWidget {
  const ScheduleScreen({super.key, this.onOpenScheduleRoutes});

  final ValueChanged<Schedule>? onOpenScheduleRoutes;

  @override
  Widget build(BuildContext context) {
    final controller = ScheduleScope.of(context);
    final schedules = controller.schedules;

    return Scaffold(
      appBar: AppBar(title: const Text('내 일정')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final saved = await Navigator.push<Schedule>(
            context,
            MaterialPageRoute(builder: (_) => const ScheduleFormScreen()),
          );
          if (saved != null && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('「${saved.title}」 일정을 저장했어요.'),
              action: saved.id == 0
                  ? null
                  : SnackBarAction(label: '경로 보기', onPressed: () => onOpenScheduleRoutes?.call(saved)),
            ));
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('일정 추가'),
      ),
      body: controller.isLoading
          ? const Center(child: CircularProgressIndicator())
          : schedules.isEmpty
          ? const Center(child: Text('등록된 일정이 없습니다.'))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 100),
              itemCount: schedules.length,
              itemBuilder: (context, index) {
                final Schedule schedule = schedules[index];

                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.event),
                    title: Text(schedule.title),
                    subtitle: Text(
                      '${schedule.location}\n'
                      '${schedule.startTime}',
                    ),
                    isThreeLine: true,
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DetailScreen(
                            title: schedule.title,
                            schedule: schedule,
                            onOpenScheduleRoutes: onOpenScheduleRoutes,
                          ),
                        ),
                      );
                    },
                    trailing: PopupMenuButton<String>(
                      onSelected: (value) async {
                        if (value == 'edit') {
                          final saved = await Navigator.push<Schedule>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ScheduleFormScreen(existing: schedule),
                            ),
                          );
                          if (saved != null && context.mounted) {
                            onOpenScheduleRoutes?.call(saved);
                          }
                        } else if (value == 'delete') {
                          controller.deleteSchedule(schedule.id);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('수정')),
                        PopupMenuItem(value: 'delete', child: Text('삭제')),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
