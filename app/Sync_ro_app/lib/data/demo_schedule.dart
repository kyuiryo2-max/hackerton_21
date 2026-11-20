import '../models/schedule.dart';
import 'presentation_demo_data.dart';

/// 시연 모드에서 할 일·일정 탭에 보여 주는 발표 시연 일정 (11/21).
/// 홈·이동 탭이 쓰는 서울역 → 고려대학교(9:20 도착) 계획과 같은 일정이에요.
/// 일정 목록(ScheduleScope)에는 넣지 않아요. 넣으면 이동 탭이 시연 계획 대신 "다음 일정" 경로로 바뀌어요.
class DemoSchedule {
  /// 저장된 일정과 겹치지 않는 표시용 id. 경로 보기는 이 id로 시연 계획에 연결해요.
  /// 수정 화면은 열 수 있지만 일정 목록에 없는 id라 저장·삭제해도 목록은 그대로예요.
  static const int id = -2026;
  static const int lunchId = -2027;

  static bool isDemo(Schedule s) => s.id == id || s.id == lunchId;
  static bool isLunch(Schedule s) => s.id == lunchId;

  /// 할 일·일정 탭에 보여 줄 시연 일정 (시간 순)
  static List<Schedule> get all => [schedule, lunch];

  /// AI 장소 추천을 보여 주는 시연 일정. 수정 화면을 열면 AI가 지금 위치 주변 일식집을 추천해요.
  /// 가게 이름은 미리 정하지 않아요. 서버 AI + 카카오 검색으로 실제로 있는 곳만 보여 줘요.
  static Schedule get lunch {
    final day = DateTime.parse(PresentationDemoData.arriveByIso).toLocal();
    final start = DateTime(day.year, day.month, day.day, 12, 30);
    return Schedule(
      id: lunchId,
      title: '일식 먹으러 가기',
      location: 'AI 추천으로 장소 고르기',
      startTime: start,
      endTime: start.add(const Duration(hours: 1)),
    );
  }

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
