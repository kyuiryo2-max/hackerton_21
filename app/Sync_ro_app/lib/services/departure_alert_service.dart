
enum DepartureAlertStatus {
  normal,
  preparing,
  leaveNow,
  overdue,
}

class DepartureAlert {
  final DepartureAlertStatus status;
  final String message;
  final int remainingMinutes;

  const DepartureAlert({
    required this.status,
    required this.message,
    required this.remainingMinutes,
  });
}

class DepartureAlertService {
  static const int travelMinutes = 35;
  static const int bufferMinutes = 10;
  static const int alertBeforeMinutes = 10;

  DateTime calculateDepartureTime(DateTime scheduleStart) {
    return scheduleStart.subtract(
      const Duration(
        minutes: travelMinutes + bufferMinutes,
      ),
    );
  }

  DepartureAlert checkDeparture({
    required DateTime scheduleStart,
    required DateTime now,
  }) {
    final departureTime = calculateDepartureTime(scheduleStart);

    final difference = departureTime.difference(now);
    final remainingMinutes = (difference.inSeconds / 60).ceil();

    if (!now.isBefore(departureTime)) {
      final overdueMinutes =
          now.difference(departureTime).inMinutes;

      if (overdueMinutes == 0) {
        return const DepartureAlert(
          status: DepartureAlertStatus.leaveNow,
          message: '지금 출발하세요!',
          remainingMinutes: 0,
        );
      }

      return DepartureAlert(
        status: DepartureAlertStatus.overdue,
        message: '추천 출발 시각이 지났습니다.',
        remainingMinutes: -overdueMinutes,
      );
    }

    if (remainingMinutes <= alertBeforeMinutes) {
      return DepartureAlert(
        status: DepartureAlertStatus.preparing,
        message: '곧 출발해야 합니다. 이동을 준비하세요!',
        remainingMinutes: remainingMinutes,
      );
    }

    return DepartureAlert(
      status: DepartureAlertStatus.normal,
      message: '아직 출발까지 여유가 있습니다.',
      remainingMinutes: remainingMinutes,
    );
  }
}
