/// 이동 중 단계 (11/13). "이동 시작"을 누른 뒤 시간이 흐르는 기준으로 지금 단계를 정해요.
/// 계획보다 빠르거나 늦으면 사용자가 "도착했어요 / 탔어요" 버튼으로 다음 단계로 넘겨요.
/// 서버 /api/ask 의 trip.phase 와 같은 이름을 써요 (server/app/services/trip.py).
enum TripPhase { toPlace, atPlace, toStop, waiting, riding, arrived }

extension TripPhaseCode on TripPhase {
  String get code => switch (this) {
        TripPhase.toPlace => 'to_place',
        TripPhase.atPlace => 'at_place',
        TripPhase.toStop => 'to_stop',
        TripPhase.waiting => 'waiting',
        TripPhase.riding => 'riding',
        TripPhase.arrived => 'arrived',
      };
}

class TripStep {
  const TripStep(this.phase, this.start);
  final TripPhase phase;
  /// 계획상 이 단계가 시작하는 시각
  final DateTime start;
}

/// 이동 하나의 계획 시각들. 숫자는 모두 앱 계산값(경로 카드·경유 계산)이에요.
class TripPlan {
  TripPlan({
    required this.depart,
    required this.reachStop,
    required this.boardAt,
    required this.arriveAt,
    required this.stopName,
    required this.rideName,
    required this.destination,
    this.placeName,
    this.arrivePlace,
    this.leavePlace,
    this.vehicleTimes = const [],
  });

  final DateTime depart;
  /// 탈 정류장에 도착하는 시각
  final DateTime reachStop;
  final DateTime boardAt;
  final DateTime arriveAt;
  final String stopName;
  /// "2115번", "2호선"
  final String rideName;
  final String destination;
  /// 들르는 곳 (적용한 할 일이 없으면 null)
  final String? placeName;
  final DateTime? arrivePlace;
  final DateTime? leavePlace;
  /// 탈 정류장에 곧 오는 차 시각 (실시간이 있을 때만)
  final List<DateTime> vehicleTimes;

  bool get hasStop => placeName != null && arrivePlace != null && leavePlace != null;

  late final List<TripStep> steps = _inOrder([
    if (hasStop) ...[
      TripStep(TripPhase.toPlace, depart),
      TripStep(TripPhase.atPlace, arrivePlace!),
      TripStep(TripPhase.toStop, leavePlace!),
    ] else
      TripStep(TripPhase.toStop, depart),
    TripStep(TripPhase.waiting, reachStop.isAfter(boardAt) ? boardAt : reachStop),
    TripStep(TripPhase.riding, boardAt),
    TripStep(TripPhase.arrived, arriveAt),
  ]);

  /// 단계 시작 시각이 앞 단계보다 빠르면 앞 단계 시각으로 맞춰요.
  /// (11/14 실제 모드: 17:21 출발인데 실시간 "3분 뒤" 버스 시각이 탑승 시각으로 들어가
  ///  16:05에 바로 "타는 중"이 됐어요. 순서가 꼬여도 단계를 건너뛰지 않게 해요)
  static List<TripStep> _inOrder(List<TripStep> raw) {
    final out = <TripStep>[];
    for (final s in raw) {
      final prev = out.isEmpty ? null : out.last.start;
      out.add(prev != null && s.start.isBefore(prev) ? TripStep(s.phase, prev) : s);
    }
    return out;
  }

  /// 출발 시각 전인지 (이동 시작을 일찍 눌렀을 때)
  bool beforeDepart(DateTime now) => now.isBefore(depart);

  /// 시간 기준 지금 단계 (시작 시각이 지난 마지막 단계)
  int indexAt(DateTime now) {
    var index = 0;
    for (var i = 0; i < steps.length; i++) {
      if (!now.isBefore(steps[i].start)) index = i;
    }
    return index;
  }

  /// 전체 진행률 0~1. 버튼으로 앞 단계로 넘겼으면 그 단계 시작보다 뒤로 가지 않아요
  double progressAt(DateTime now, int index) {
    final total = arriveAt.difference(depart).inSeconds;
    if (total <= 0) return index >= steps.length - 1 ? 1 : 0;
    final byTime = now.difference(depart).inSeconds / total;
    final byStep = steps[index].start.difference(depart).inSeconds / total;
    return (byTime > byStep ? byTime : byStep).clamp(0.0, 1.0).toDouble();
  }

  /// 지금부터 그 시각까지 남은 분 (지났으면 0)
  static int minutesUntil(DateTime t, DateTime now) {
    final m = t.difference(now).inSeconds ~/ 60;
    return m < 0 ? 0 : m;
  }

  /// 지금 기준으로 아직 안 지나간 차 (분)
  List<int> soonMinutes(DateTime now) => [
        for (final t in vehicleTimes)
          if (!t.isBefore(now)) minutesUntil(t, now),
      ];

  /// 서버 /api/ask 의 trip 값
  Map<String, dynamic> toAskJson(TripPhase phase, DateTime now) => {
        'phase': phase.code,
        'now': _iso(now),
        if (hasStop) 'place_name': placeName,
        if (hasStop) 'leave_place_at': _iso(leavePlace!),
        'stop_name': stopName,
        'board_at': _iso(boardAt),
        'ride_name': rideName,
        'arrive_at': _iso(arriveAt),
        'destination': destination,
        'next_vehicles_min': soonMinutes(now),
      };

  /// 한국 시간 ISO 8601 (+09:00)
  static String _iso(DateTime t) {
    final k = t.toUtc().add(const Duration(hours: 9));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${k.year}-${two(k.month)}-${two(k.day)}T${two(k.hour)}:${two(k.minute)}:${two(k.second)}+09:00';
  }
}
