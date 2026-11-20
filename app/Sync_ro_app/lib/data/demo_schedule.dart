import '../models/schedule.dart';
import 'presentation_demo_data.dart';

/// 시연 모드에서 할 일·일정 탭에 보여 주는 발표 시연 일정 (11/21).
/// 홈·이동 탭이 쓰는 서울역 → 고려대학교(9:20 도착) 계획과 같은 일정이에요.
/// 일정 목록(ScheduleScope)에는 넣지 않아요. 넣으면 이동 탭이 시연 계획 대신 "다음 일정" 경로로 바뀌어요.
class DemoSchedule {
  /// 저장된 일정과 겹치지 않는 표시용 id. 수정·삭제·경로 보기는 이 id로 걸러요.
  static const int id = -2026;

  static bool isDemo(Schedule s) => s.id == id;

  static Schedule get schedule {
    final ctx = PresentationDemoData.context;
    final sched = Map<String, dynamic>.from(ctx['schedule'] as Map);
    final dest = Map<String, dynamic>.from(sched['destination'] as Map);
    final loc = Map<String, dynamic>.from(ctx['location'] as Map);
    final arrive = DateTime.parse(PresentationDemoData.arriveByIso).toLocal();
    return Schedule(
      id: id,
      title: '${dest['name']} 가기',
      location: '${dest['name']}',
      destinationLatitude: (dest['lat'] as num).toDouble(),
      destinationLongitude: (dest['lng'] as num).toDouble(),
      originMode: 'place',
      originName: '${loc['name']}',
      originLatitude: (loc['lat'] as num).toDouble(),
      originLongitude: (loc['lng'] as num).toDouble(),
      startTime: arrive,
      endTime: arrive.add(const Duration(hours: 1, minutes: 30)),
      preparationMinutes: (sched['prep_minutes'] as num?)?.toInt() ?? 30,
    );
  }
}
