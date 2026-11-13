import 'dart:math' as math;

import '../services/server_plan_service.dart';

/// 홈 첫 화면에서 쓰는 "언제 나가야 하는지 + 들를 곳에서 얼마나 머물 수 있는지" 요약.
///
/// 숫자는 서버 계산값(board_at, max_stay_min, detour_min, stay_min)을 쓰고,
/// 앱은 출발 시각을 옮겼을 때의 뺄셈만 해요.
///   탈 차 시각(board_at)은 고정 → 늦게 나간 만큼 경유지에서 쓸 시간이 줄어요.
///   머무를 수 있는 시간 = 여유(spare) − 경유 왕복 도보 − 늦게 나간 분
///   (spare = 서버 max_stay_min + 서버가 포함한 경유지 도보, 즉 경유를 안 할 때 정류장 근처에서 남는 시간)
enum DepartureSource {
  /// 서버 시연 계획 (/api/plan, demo=true)
  serverDemo,
  /// 서버가 꺼져 있을 때 앱에 들어 있는 시연 예시
  offlineDemo,
  /// 이동 탭에서 고른 경로 + 서버 계획
  serverPlan,
  /// 이동 탭에서 고른 경로 (서버 계획 없음, 소요시간으로 역산)
  selectedRoute,
  /// 일정만 있고 경로가 없을 때 임시 추정
  scheduleEstimate,
}

class GeoPoint {
  const GeoPoint(this.name, this.lat, this.lng);
  final String name;
  final double lat;
  final double lng;

  static GeoPoint? fromJson(dynamic raw, {String fallbackName = ''}) {
    if (raw is! Map) return null;
    final lat = raw['lat'], lng = raw['lng'];
    if (lat is! num || lng is! num) return null;
    return GeoPoint('${raw['name'] ?? fallbackName}', lat.toDouble(), lng.toDouble());
  }
}

/// 할 일 하나를 처리할 수 있는 장소 후보.
class StayCandidate {
  const StayCandidate({
    required this.id,
    required this.name,
    required this.detourMinutes,
    this.address,
    this.placeType,
    this.point,
    this.walkToMinutes,
    this.walkBackMinutes,
    this.openAt,
    this.closeAt,
  });

  final String id;
  final String name;
  final String? address;
  final String? placeType;
  final GeoPoint? point;
  /// 경유하느라 늘어나는 왕복 도보(분)
  final int detourMinutes;
  final int? walkToMinutes;
  final int? walkBackMinutes;
  /// 영업시간 "HH:mm" (서버가 줄 때만)
  final String? openAt;
  final String? closeAt;

  /// 서버가 편도를 안 주면 왕복을 반으로 나눠 추정해요 (화면에 "약"으로 표시).
  bool get walkSplitEstimated => walkToMinutes == null || walkBackMinutes == null;
  int get walkTo => walkToMinutes ?? (detourMinutes + 1) ~/ 2;
  int get walkBack => walkBackMinutes ?? detourMinutes - walkTo;

  /// 주소에서 동네 이름만 짧게 (예: "서울 성북구 고려대로28길 16" → "고려대로28길")
  String get shortArea {
    final parts = (address ?? '').split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 3) return parts[2];
    return placeType ?? '';
  }
}

/// 가는 길에 할 일 (서버 todo 하나).
class StayTask {
  const StayTask({
    required this.id,
    required this.title,
    required this.importance,
    required this.serverStatus,
    required this.needMinutes,
    required this.candidates,
    this.needFromServer = false,
    this.reason = '',
  });

  final String id;
  final String title;
  final String importance;
  /// 서버 판단: 포함 / 대기 / 제외
  final String serverStatus;
  /// 그 장소에서 꼭 필요한 시간(분)
  final int needMinutes;
  final bool needFromServer;
  final List<StayCandidate> candidates;
  final String reason;

  bool get isRequired => importance == '필수';
  bool get includedByServer => serverStatus == '포함';
}

enum StayStatus { ok, tight, bad }

/// 출발 시각 하나 + 후보 하나에 대한 판정.
class StayEval {
  const StayEval({
    required this.candidate,
    required this.status,
    required this.dwell,
    required this.need,
    required this.depart,
    required this.arrivePlace,
    required this.waitMinutes,
    required this.leavePlace,
    required this.reachStop,
    required this.missesVehicle,
    required this.closeLimited,
    this.latestDepart,
    this.ample = false,
    int? maxDwell,
  }) : maxDwell = maxDwell ?? dwell;

  final StayCandidate candidate;
  final StayStatus status;
  /// 머무를 수 있는 최대 시간(분). 음수면 그만큼 모자라요.
  final int dwell;
  final int need;
  final DateTime depart;
  final DateTime arrivePlace;
  /// 오픈 전에 도착하면 기다리는 시간
  final int waitMinutes;
  /// ok/tight: 늦어도 이때 나와야 해요. bad: 필요한 만큼 머물면 이때 나와요.
  final DateTime leavePlace;
  final DateTime reachStop;
  final bool missesVehicle;
  final bool closeLimited;
  /// 필요한 시간을 확보하려면 늦어도 이때 출발. 영업시간 때문에 불가능하면 null.
  final DateTime? latestDepart;

  /// 시간이 넉넉해서 추천 머무는 시간([dwell])만큼만 잡고 출발을 늦췄어요.
  /// 이때 [maxDwell]은 실제로 가능한 최대치(수백 분일 수 있어 화면엔 안 보여요).
  final bool ample;
  final int maxDwell;

  int get shortBy => need - dwell;

  /// 화면용 머무는 시간 문구: "충분해요" / "최대 6분" / "0분"
  String get stayLabel => ample ? '충분해요' : (dwell <= 0 ? '0분' : '최대 $dwell분');

  /// 넉넉할 때 잡는 추천 머무는 시간: 짧은 일은 필요 시간의 2배, 긴 일은 1.5배 (최소 필요+3분)
  static int recommendFor(int need) {
    final r = need <= 10 ? need * 2 : (need * 1.5).ceil();
    return math.max(r, need + DepartureOverview.comfortMinutes);
  }
}

class DepartureOverview {
  const DepartureOverview({
    required this.source,
    required this.title,
    required this.destination,
    required this.prepMinutes,
    this.departure,
    this.boardAt,
    this.arriveAt,
    this.arriveBy,
    this.transitLabel,
    this.routeName,
    this.boardStopName,
    this.spareMinutes,
    this.tasks = const [],
    this.explanation = '',
    this.demoNow,
    this.totalMinutes,
    this.origin,
    this.destinationPoint,
    this.leaveEarlier = false,
  });

  /// 일정이 아직 멀어서(도착 시각에서 거꾸로 계산, 실시간 차 없음) 서버가 체류 여유(max_stay_min)를 안 줄 때.
  /// 이때는 "더 일찍 나가면" 들를 수 있어요: 지금 나간다고 보고, 원래 출발 시각까지를 여유로 계산해요.
  final bool leaveEarlier;

  /// 정류장에 미리 도착해 있는 여유 (server timecalc.STOP_BUFFER_SECONDS 와 같은 값)
  static const int stopBufferMinutes = 2;
  /// 필요 시간보다 이만큼 이상 남으면 "여유", 아니면 "빠듯"
  static const int comfortMinutes = 3;

  final DepartureSource source;
  final String title;
  final String destination;
  final int prepMinutes;
  final DateTime? departure;
  final DateTime? boardAt;
  final DateTime? arriveAt;
  final DateTime? arriveBy;
  final String? transitLabel;
  final String? routeName;
  final String? boardStopName;
  final int? totalMinutes;
  final int? spareMinutes;
  final List<StayTask> tasks;
  final String explanation;
  final GeoPoint? origin;
  final GeoPoint? destinationPoint;

  /// 시연 계획의 고정 "지금" 시각. 실제 모드에서는 null.
  final DateTime? demoNow;

  bool get isDemo => source == DepartureSource.serverDemo || source == DepartureSource.offlineDemo;
  bool get isEstimate => source == DepartureSource.scheduleEstimate;
  bool get canPlanStay => (spareMinutes != null || leaveEarlier) && departure != null && boardAt != null;

  /// 체류 판정의 기준 출발 시각과 여유(분)
  (DateTime, int) get _stayBase {
    final dep = departure!;
    if (spareMinutes != null || !leaveEarlier) return (dep, spareMinutes ?? 0);
    final now = DateTime.now();
    final base = now.isBefore(dep) ? now : dep;
    return (base, dep.difference(base).inMinutes);
  }

  DateTime? get prepStart => departure?.subtract(Duration(minutes: prepMinutes));

  static DateTime? _atClock(DateTime base, String? hhmm) {
    if (hhmm == null) return null;
    final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(hhmm);
    if (m == null) return null;
    // 서버 시각은 KST 기준이라 KST 벽시계로 맞춘 뒤 UTC로 돌려놔요.
    final kst = base.toUtc().add(const Duration(hours: 9));
    final local = DateTime.utc(kst.year, kst.month, kst.day, int.parse(m.group(1)!), int.parse(m.group(2)!));
    return local.subtract(const Duration(hours: 9));
  }

  /// [delayMinutes]만큼 늦게(음수면 일찍) 나갈 때 [candidate]에서 [need]분 머무는 판정.
  ///
  /// 머무를 수 있는 시간이 추천 시간(필요의 1.5~2배)보다 많으면 추천 시간만큼만 잡고
  /// 출발을 그만큼 늦춰요(ample). 수백 분 여유를 그대로 보여 주지 않으려고요.
  StayEval evaluate(StayCandidate candidate, {required int delayMinutes, required int need}) {
    final (dep, _) = _stayBase;
    final first = _evaluateAt(candidate, dep.add(Duration(minutes: delayMinutes)), need);
    final rec = StayEval.recommendFor(need);
    if (first.dwell <= rec) return first;
    // 경유지를 나와야 하는 시각에서 거꾸로: 추천 시간 + 가는 도보만큼 전에 출발
    final mustLeave = first.leavePlace;
    final later = mustLeave.subtract(Duration(minutes: rec + candidate.walkTo));
    final shifted = _evaluateAt(candidate, later.isAfter(first.depart) ? later : first.depart, need);
    if (shifted.dwell < need + comfortMinutes) return first;
    return StayEval(
      candidate: shifted.candidate,
      status: StayStatus.ok,
      dwell: shifted.dwell,
      need: need,
      depart: shifted.depart,
      arrivePlace: shifted.arrivePlace,
      waitMinutes: shifted.waitMinutes,
      leavePlace: shifted.leavePlace,
      reachStop: shifted.reachStop,
      missesVehicle: shifted.missesVehicle,
      closeLimited: shifted.closeLimited,
      latestDepart: shifted.latestDepart,
      ample: true,
      maxDwell: first.dwell,
    );
  }

  StayEval _evaluateAt(StayCandidate candidate, DateTime depart, int need) {
    final (dep, spare) = _stayBase;
    final board = boardAt!;
    final arrive = depart.add(Duration(minutes: candidate.walkTo));

    // 정류장으로 돌아가기 시작해야 하는 시각 (탈 차 − 여유 − 돌아가는 도보)
    var mustLeave = dep.add(Duration(minutes: spare - candidate.walkBack));
    final openAt = _atClock(dep, candidate.openAt);
    final closeAt = _atClock(dep, candidate.closeAt);
    final start = openAt != null && openAt.isAfter(arrive) ? openAt : arrive;
    final wait = start.difference(arrive).inMinutes;
    var closeLimited = false;
    if (closeAt != null && closeAt.isBefore(mustLeave)) {
      mustLeave = closeAt;
      closeLimited = true;
    }
    final dwell = mustLeave.difference(start).inMinutes;

    final status = dwell >= need + comfortMinutes
        ? StayStatus.ok
        : dwell >= need
            ? StayStatus.tight
            : StayStatus.bad;

    // 필요한 시간을 확보할 수 있는 가장 늦은 출발
    DateTime? latest = mustLeave.subtract(Duration(minutes: need + candidate.walkTo));
    if (openAt != null && openAt.add(Duration(minutes: need)).isAfter(mustLeave)) latest = null;

    final leave = status == StayStatus.bad ? start.add(Duration(minutes: need)) : mustLeave;
    final reach = leave.add(Duration(minutes: candidate.walkBack));
    return StayEval(
      candidate: candidate,
      status: status,
      dwell: dwell,
      need: need,
      depart: depart,
      arrivePlace: arrive,
      waitMinutes: wait,
      leavePlace: leave,
      reachStop: reach,
      missesVehicle: reach.isAfter(board),
      closeLimited: closeLimited,
      latestDepart: latest,
    );
  }

  /// 후보를 "갈 수 있음 → 빠듯 → 부족", 같은 상태면 오래 머물 수 있는 순서로.
  List<StayEval> rank(StayTask task, {required int delayMinutes, required int need}) {
    final list = task.candidates.map((c) => evaluate(c, delayMinutes: delayMinutes, need: need)).toList();
    list.sort((a, b) {
      final s = a.status.index.compareTo(b.status.index);
      return s != 0 ? s : b.maxDwell.compareTo(a.maxDwell);
    });
    return list;
  }

  /// 아무 데도 안 들를 때 늦어도 이때 나가면 탈 수 있어요.
  DateTime? get latestDirectDeparture =>
      departure == null || spareMinutes == null ? null : departure!.add(Duration(minutes: spareMinutes!));

  // ---------- 서버 응답 → 화면 모델 ----------

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  static int? _int(dynamic value) => value is num ? value.round() : int.tryParse('${value ?? ''}');

  static String? _transitLabel(Map<String, dynamic> route) {
    final type = '${route['type'] ?? ''}'.toUpperCase();
    final name = '${route['name'] ?? ''}'.trim();
    if (type.contains('BUS')) return name.isEmpty ? '버스' : (name.endsWith('번') ? '$name 버스' : '$name번 버스');
    if (type.contains('SUBWAY') || type.contains('METRO') || type.contains('TRAIN')) {
      return name.isEmpty ? '지하철' : '지하철 $name';
    }
    if (type.contains('WALK')) return '도보';
    return name.isEmpty ? null : name;
  }

  static StayCandidate? _candidate(Map<String, dynamic> raw, String id, {int? detourFallback}) {
    final detour = _int(raw['detour_min']) ?? detourFallback;
    if (detour == null) return null;
    return StayCandidate(
      id: id,
      name: '${raw['name'] ?? raw['place_type'] ?? '장소'}',
      address: raw['address']?.toString(),
      placeType: raw['place_type']?.toString(),
      point: GeoPoint.fromJson(raw),
      detourMinutes: detour,
      walkToMinutes: _int(raw['walk_to_min']),
      walkBackMinutes: _int(raw['walk_back_min']),
      openAt: raw['open']?.toString(),
      closeAt: raw['close']?.toString(),
    );
  }

  /// 서버 /api/plan 응답(docs/design/api-examples/plan.json 형식)을 홈 화면 모델로 바꿔요.
  ///
  /// 할 일마다 `candidates`(후보 여러 곳)가 오면 모두 비교하고,
  /// 없으면 지금처럼 `place` + `detour_min` 한 곳만 보여 줘요.
  static DepartureOverview fromPlan(
    ServerPlan plan, {
    required DepartureSource source,
    String? title,
    String? destination,
    int? fallbackPrepMinutes,
    DateTime? fallbackArriveBy,
    GeoPoint? fallbackOrigin,
    int Function(String todoTitle)? fallbackNeedMinutes,
  }) {
    final schedule = _map(plan.data['schedule']);
    final dest = _map(schedule['destination']);
    final routes = plan.routes
      ..sort((a, b) => (_int(a['rank']) ?? 99).compareTo(_int(b['rank']) ?? 99));
    final route = routes.isEmpty ? <String, dynamic>{} : routes.first;
    final stopsOnRoute = route['stops'] is List ? route['stops'] as List : const [];

    final tasks = <StayTask>[];
    var includedDetour = 0;
    for (final todo in plan.todos) {
      final id = '${todo['todo_id'] ?? tasks.length}';
      final status = '${todo['status'] ?? ''}';
      final place = _map(todo['place']);
      final mainDetour = _int(todo['detour_min']);
      if (status == '포함' && mainDetour != null) includedDetour += mainDetour;

      final candidates = <StayCandidate>[];
      final rawCandidates = todo['candidates'];
      if (rawCandidates is List && rawCandidates.isNotEmpty) {
        for (var i = 0; i < rawCandidates.length; i++) {
          final c = _candidate(_map(rawCandidates[i]), '$id-$i');
          if (c != null) candidates.add(c);
        }
      } else if (place.isNotEmpty) {
        final c = _candidate(place, '$id-0', detourFallback: mainDetour);
        if (c != null) candidates.add(c);
      }
      if (candidates.isEmpty) continue;

      final todoTitle = '${todo['text'] ?? '할 일'}';
      final serverNeed = _int(todo['stay_min']);
      tasks.add(StayTask(
        id: id,
        title: todoTitle,
        importance: '${todo['importance'] ?? '선택'}',
        serverStatus: status,
        needMinutes: math.max(1, serverNeed ?? fallbackNeedMinutes?.call(todoTitle) ?? 5),
        needFromServer: serverNeed != null,
        candidates: candidates,
        reason: '${todo['reason'] ?? ''}',
      ));
    }
    // 필수 → 서버가 포함한 순서로
    tasks.sort((a, b) {
      final inc = (b.includedByServer ? 1 : 0).compareTo(a.includedByServer ? 1 : 0);
      if (inc != 0) return inc;
      return (b.isRequired ? 1 : 0).compareTo(a.isRequired ? 1 : 0);
    });
    final maxStay = _int(route['max_stay_min']);

    return DepartureOverview(
      source: source,
      title: title ?? '${dest['name'] ?? destination ?? '목적지'} 가기',
      destination: destination ?? '${dest['name'] ?? '목적지'}',
      prepMinutes: _int(schedule['prep_minutes']) ?? fallbackPrepMinutes ?? 30,
      departure: plan.departureAt,
      boardAt: plan.boardAt,
      arriveAt: plan.arriveAt,
      arriveBy: DateTime.tryParse('${schedule['arrive_by'] ?? ''}') ?? fallbackArriveBy,
      transitLabel: _transitLabel(route),
      routeName: route['name']?.toString(),
      boardStopName: stopsOnRoute.isEmpty ? null : '${stopsOnRoute.first}',
      totalMinutes: _int(route['total_min']),
      spareMinutes: maxStay == null ? null : maxStay + includedDetour,
      // 일정이 멀어서 실시간 차가 없을 때(도착 시각에서 거꾸로): 더 일찍 나가는 걸로 계산
      leaveEarlier: maxStay == null && '${route['basis'] ?? plan.basis ?? ''}' == 'arrive_by',
      tasks: tasks,
      explanation: plan.explanation,
      origin: GeoPoint.fromJson(plan.data['origin'], fallbackName: '출발') ?? fallbackOrigin,
      destinationPoint: GeoPoint.fromJson(dest),
      demoNow: source == DepartureSource.serverDemo || source == DepartureSource.offlineDemo
          ? DateTime.tryParse('${plan.data['now'] ?? ''}')
          : null,
    );
  }
}
