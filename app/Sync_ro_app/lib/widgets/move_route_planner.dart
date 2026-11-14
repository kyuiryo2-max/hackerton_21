import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../config/app_theme.dart';
import '../data/demo_route_style.dart';
import '../models/departure_overview.dart';
import '../models/route_candidate.dart';
import '../providers/active_route_controller.dart';
import '../services/kst_time.dart';
import '../services/server_plan_service.dart';
import 'home/stay_planner_card.dart';
import 'route_compare_map.dart';
import '../providers/todo_controller.dart';
import 'specialty_chips.dart';
import '../models/trip_progress.dart';
import '../services/server_ask_service.dart';
import 'trip_panel.dart';
import '../models/schedule.dart';
import '../screens/schedule_form_screen.dart';
import '../services/schedule_draft_parser.dart';

/// 이동 탭 (팀장님 흐름도 기준)
/// ① 일정 이름 · 출발지 → 목적지   ② 지도 (경로 · 출발지 · 목적지 · 경유 후보)
/// ③ 추천 경로 카드 (출발 → 도착, 도착 여유)   ④ "할 일 적용하기" → 경유 가능한 할 일만 고르는 창
/// ⑤ 선택한 경로 상세 (출발·도착·여유, 할 일을 적용했으면 머무는 시간)   ⑥ 이 경로로 이동 시작
class MoveRoutePlanner extends StatefulWidget {
  const MoveRoutePlanner({
    super.key,
    required this.routes,
    required this.selectedId,
    required this.onSelect,
    required this.title,
    required this.originName,
    required this.destinationName,
    required this.now,
    this.plan,
    this.arriveBy,
    this.origin,
    this.destination,
    this.isDemo = false,
    this.badge,
    this.onManageSchedule,
    this.onOpenAssistant,
    this.fallbackNeed,
    this.onRefresh,
  });

  final List<RouteCandidate> routes;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final String title;
  final String originName;
  final String destinationName;
  /// 기준 시각 (시연이면 시연 시각)
  final DateTime now;
  final ServerPlan? plan;
  final DateTime? arriveBy;
  final LatLng? origin;
  final LatLng? destination;
  final bool isDemo;
  final String? badge;
  final VoidCallback? onManageSchedule;
  final ValueChanged<String?>? onOpenAssistant;
  final int Function(String todoTitle)? fallbackNeed;
  /// 경로를 다시 불러와요 (실시간 정보 새로고침, 11/13)
  final VoidCallback? onRefresh;

  @override
  State<MoveRoutePlanner> createState() => _MoveRoutePlannerState();
}

/// 경로 한 개의 시각
class _RouteTimes {
  const _RouteTimes(this.depart, this.arrive, this.derived, [this.viaStop = false]);
  final DateTime depart;
  final DateTime arrive;
  /// 실시간·시간표 없이 소요시간으로 역산한 값
  final bool derived;
  /// 적용한 할 일 경유지에 들렀다 가는 시각 (출발이 그만큼 당겨져요)
  final bool viaStop;
  int get minutes => arrive.difference(depart).inMinutes;
}

class _MoveRoutePlannerState extends State<MoveRoutePlanner> {
  static const int _departBuffer = 5; // 정류장에 미리 도착해 있는 여유 (서버 timecalc 와 같은 값)

  String? _appliedTaskId;
  String? _candidateId;
  final Map<String, int> _needOverride = {};
  bool _tripStarted = false;

  // ---------- 이동 중 (11/13): 시간 기준 단계 + 버튼으로 넘기기 ----------
  DateTime? _tripRealStart;
  int _tripSkipMinutes = 0;
  int _tripManualIndex = 0;
  /// 버튼으로 다음 단계로 넘긴 시각. 계획보다 일찍 넘겼으면 그 단계는 이때부터 진행한 걸로 봐요 (11/14)
  DateTime? _manualAt;
  Timer? _tripTick;
  /// 실제 모드: 이동 중 실제 위치 (11/14). 시연 모드는 계획 시각 기준으로 추정해요
  StreamSubscription<Position>? _gpsSub;
  /// 실제 위치가 지금 단계의 길에서 이만큼(m) 안이면 실제 위치로, 더 멀면 계획 시각 기준으로 그려요
  static const double _gpsOnPathMeters = 120;
  LatLng? _gps;
  double? _gpsHeading;
  /// 도착 단계가 되면 잠시 보여 준 뒤 이동을 자동으로 마쳐요 (#51 피드백 4)
  Timer? _arriveEnd;
  static const _arriveShowSeconds = 6;
  final _mapKey = GlobalKey();
  final _askService = ServerAskService();

  /// 이동 중 시계. 시연 모드는 시연 시각에서, 실제 모드는 지금 시각에서 흘러가요.
  /// "1분 뒤" 버튼(시연)은 시계를 앞으로 보내요.
  DateTime get _tripClock {
    final skip = Duration(minutes: _tripSkipMinutes);
    if (widget.isDemo) {
      final ran = DateTime.now().difference(_tripRealStart ?? DateTime.now());
      return widget.now.add(ran).add(skip);
    }
    return DateTime.now().add(skip);
  }

  void _startTrip() {
    _arriveEnd?.cancel();
    _arriveEnd = null;
    _tripRealStart = DateTime.now();
    _startGps();
    _tripSkipMinutes = 0;
    _tripManualIndex = 0;
    _manualAt = null;
    _tripTick?.cancel();
    // "N분 남음"과 지도 화살표가 움직이도록 5초마다 다시 그려요
    _tripTick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _mapKey.currentContext;
      if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350));
    });
  }

  /// 실제 모드에서 이동을 시작하면 위치를 계속 받아요 (움직일 때 3m마다)
  void _startGps() {
    _stopGps();
    if (widget.isDemo) return;
    try {
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 3),
      ).listen((p) {
        if (!mounted) return;
        final next = LatLng(p.latitude, p.longitude);
        double? heading;
        // 걷는 중이면 기기가 알려 주는 방향, 아니면 직전 위치에서 온 방향
        if (p.heading >= 0 && p.speed > 0.7) {
          heading = p.heading * math.pi / 180;
        } else if (_gps != null && _meters(_gps!, next) > 3) {
          heading = _heading(_gps!, next);
        }
        setState(() {
          _gps = next;
          if (heading != null) _gpsHeading = heading;
        });
      }, onError: (_) {
        // 위치를 못 받으면 계획 시각 기준 추정으로 돌아가요
        if (mounted) setState(() => _gps = null);
      });
    } catch (_) {}
  }

  void _stopGps() {
    _gpsSub?.cancel();
    _gpsSub = null;
    _gps = null;
    _gpsHeading = null;
  }

  static double _meters(LatLng a, LatLng b) {
    final dx = (a.longitude - b.longitude) * 111320 * math.cos(a.latitude * math.pi / 180);
    final dy = (a.latitude - b.latitude) * 110540;
    return math.sqrt(dx * dx + dy * dy);
  }

  void _stopTrip() {
    _stopGps();
    _tripTick?.cancel();
    _tripTick = null;
    _arriveEnd?.cancel();
    _arriveEnd = null;
  }

  /// 이동 종료: 아래 버튼, 팝업 버튼, 도착 후 자동 종료가 모두 여기로 와요
  void _endTrip({bool arrived = false}) {
    if (!_tripStarted || !mounted) return;
    setState(() {
      _tripStarted = false;
      _stopTrip();
    });
    if (arrived) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${widget.destinationName}에 도착해서 이동을 마쳤어요.')));
    }
  }

  /// 도착 단계에 들어서면 한 번만 자동 종료를 걸어 둬요
  void _maybeAutoEnd(TripPlan? trip, int index) {
    if (trip == null || _arriveEnd != null) return;
    if (trip.steps[index].phase != TripPhase.arrived) return;
    _arriveEnd = Timer(const Duration(seconds: _arriveShowSeconds), () => _endTrip(arrived: true));
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _arriveEnd?.cancel();
    _tripTick?.cancel();
    _askService.dispose();
    super.dispose();
  }

  /// 이동 하나의 계획 시각 (카드·경유 계산과 같은 값)
  TripPlan _tripPlan(RouteCandidate route, StayTask? applied, StayEval? chosen) {
    final times = _shownTimes(route, applied, chosen: chosen);
    final o = _overviewFor(route);
    final p = _planRouteFor(route);
    final segs = route.segments;
    final firstWalk = segs.isNotEmpty && segs.first.type == RouteSegmentType.walking ? segs.first.durationMinutes : 0;
    final firstRide = segs.where((s) => s.type == RouteSegmentType.bus || s.type == RouteSegmentType.subway);
    final ride = firstRide.isEmpty ? null : firstRide.first;
    // 들르는 곳 (경유를 계산할 수 있을 때만). 지역 변수라 아래에서 null 검사가 그대로 이어져요
    final stop = times.viaStop && chosen != null && chosen.status != StayStatus.bad ? chosen : null;
    final reachStop = stop != null
        ? stop.leavePlace.add(Duration(minutes: stop.candidate.walkBack))
        : times.depart.add(Duration(minutes: firstWalk));
    // 계산한 탑승 시각이 정류장 도착보다 이르면(= 지금 오는 실시간 버스 시각) 정류장 도착 시각을 써요 (11/14)
    final given = o?.boardAt;
    final boardAt = given != null && !given.isBefore(reachStop) ? given : reachStop;
    final planNow = DateTime.tryParse('${widget.plan?.data['now'] ?? ''}') ?? widget.now;
    final raw = p?['next_vehicles_min'];
    return TripPlan(
      depart: times.depart,
      reachStop: reachStop,
      boardAt: boardAt,
      arriveAt: times.arrive,
      stopName: o?.boardStopName ?? ride?.startName ?? '정류장',
      rideName: _rideNameOf(p, ride),
      destination: widget.destinationName,
      placeName: stop?.candidate.name,
      arrivePlace: stop?.arrivePlace,
      leavePlace: stop?.leavePlace,
      vehicleTimes: [
        if (raw is List)
          for (final v in raw)
            if (v is num) planNow.add(Duration(minutes: v.toInt())),
      ],
    );
  }

  /// 안내에 쓸 노선 이름: 서버 ride_name → 버스 번호면 "번"을 붙여요 ("2115" → "2115번", "2호선" 그대로)
  static String _rideNameOf(Map<String, dynamic>? p, RouteSegment? ride) {
    final given = p?['ride_name'];
    if (given is String && given.isNotEmpty) return given;
    final name = '${p?['name'] ?? ride?.lineName ?? ''}'.trim();
    if (name.isEmpty) return ride?.description ?? '탈 차';
    final last = name.codeUnitAt(name.length - 1);
    final endsWithDigit = last >= 48 && last <= 57;
    return endsWithDigit && ride?.type != RouteSegmentType.subway ? '$name번' : name;
  }

  int _tripIndex(TripPlan plan) {
    final byTime = plan.indexAt(_tripClock);
    final i = byTime > _tripManualIndex ? byTime : _tripManualIndex;
    return i.clamp(0, plan.steps.length - 1).toInt();
  }

  /// 점들을 이은 선에서 비율 f(0~1) 위치
  static LatLng? _along(List<LatLng> pts, double f) {
    if (pts.isEmpty) return null;
    if (pts.length == 1) return pts.first;
    double d(LatLng a, LatLng b) =>
        math.sqrt(math.pow(a.latitude - b.latitude, 2) + math.pow(a.longitude - b.longitude, 2));
    final lengths = [for (var i = 0; i + 1 < pts.length; i++) d(pts[i], pts[i + 1])];
    final total = lengths.fold<double>(0, (a, b) => a + b);
    if (total == 0) return pts.first;
    var target = total * f.clamp(0.0, 1.0);
    for (var i = 0; i < lengths.length; i++) {
      if (target <= lengths[i] || i == lengths.length - 1) {
        final t = lengths[i] == 0 ? 0.0 : (target / lengths[i]).clamp(0.0, 1.0);
        final a = pts[i], b = pts[i + 1];
        return LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
      }
      target -= lengths[i];
    }
    return pts.last;
  }

  static double _fraction(DateTime now, DateTime from, DateTime to) {
    final total = to.difference(from).inSeconds;
    if (total <= 0) return 1;
    return (now.difference(from).inSeconds / total).clamp(0.0, 1.0).toDouble();
  }

  /// 점들을 이은 선에서 처음부터 비율 f(0~1) 지점까지 (지나온 길). 마지막 점이 지금 위치예요
  static List<LatLng> _prefix(List<LatLng> pts, double f) {
    if (pts.length < 2) return List.of(pts);
    final here = _along(pts, f)!;
    double d(LatLng a, LatLng b) =>
        math.sqrt(math.pow(a.latitude - b.latitude, 2) + math.pow(a.longitude - b.longitude, 2));
    final lengths = [for (var i = 0; i + 1 < pts.length; i++) d(pts[i], pts[i + 1])];
    var target = lengths.fold<double>(0, (a, b) => a + b) * f.clamp(0.0, 1.0);
    final out = <LatLng>[pts.first];
    for (var i = 0; i < lengths.length; i++) {
      if (target <= lengths[i]) break;
      target -= lengths[i];
      out.add(pts[i + 1]);
    }
    out.add(here);
    return out;
  }

  /// 지도 화면에서 a → b 방향 (북쪽 0, 시계 방향 라디안). 짧은 거리라 위도 보정만 해요
  static double? _heading(LatLng a, LatLng b) {
    final dx = (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180);
    final dy = b.latitude - a.latitude;
    if (dx.abs() < 1e-9 && dy.abs() < 1e-9) return null;
    return math.atan2(dx, dy);
  }

  /// 단계 하나에서 지나는 길과, 그 단계에서 얼마나 왔는지 (시간 기준)
  (List<LatLng>, double) _stepTrack(TripPlan plan, int i, RouteCandidate route, StayEval? chosen, DateTime now) {
    final step = plan.steps[i];
    final segs = route.segments;
    List<LatLng> geo(RouteSegment s) => [for (final p in s.geometry) LatLng(p.latitude, p.longitude)];
    final rideAt = segs.indexWhere((s) => s.type == RouteSegmentType.bus || s.type == RouteSegmentType.subway);
    final place = chosen?.candidate.point == null ? null : LatLng(chosen!.candidate.point!.lat, chosen.candidate.point!.lng);
    final boardPt = rideAt < 0 || segs[rideAt].geometry.isEmpty ? null : geo(segs[rideAt]).first;
    switch (step.phase) {
      case TripPhase.toPlace:
        final path = [for (final p in chosen?.candidate.pathTo ?? const <GeoPoint>[]) LatLng(p.lat, p.lng)];
        final pts = path.length >= 2 ? path : [if (widget.origin != null) widget.origin!, if (place != null) place];
        return (pts, _fraction(now, plan.depart, plan.arrivePlace!));
      case TripPhase.atPlace:
        return ([if (place != null) place], 1);
      case TripPhase.toStop:
        final back = [for (final p in chosen?.candidate.pathBack ?? const <GeoPoint>[]) LatLng(p.lat, p.lng)];
        final pts = plan.hasStop
            ? (back.length >= 2 ? back : [if (place != null) place, if (boardPt != null) boardPt])
            : (segs.isNotEmpty && segs.first.type == RouteSegmentType.walking ? geo(segs.first) : <LatLng>[]);
        return (pts, _fraction(now, step.start, plan.reachStop));
      case TripPhase.waiting:
        return ([if (boardPt != null) boardPt], 1);
      case TripPhase.riding:
        final pts = [if (rideAt >= 0) for (final s in segs.skip(rideAt)) ...geo(s)];
        return (pts, _fraction(now, plan.boardAt, plan.arriveAt));
      case TripPhase.arrived:
        return ([if (widget.destination != null) widget.destination!], 1);
    }
  }

  /// 이동 중 지도 표시 (#51 피드백: 현 상황에 따라 움직이는 화살표와 지나온 길)
  /// dot: 지금 있을 것 같은 곳, heading: 가는 방향, passed: 지나온 길 (회색으로 덮어요)
  ({LatLng? dot, double? heading, List<LatLng> passed}) _tripTrack(
      TripPlan plan, int index, RouteCandidate route, StayEval? chosen) {
    final now = _tripClock;
    final gps = _gps;
    if (gps != null) {
      final real = _gpsTrack(plan, index, route, chosen, now, gps);
      if (real != null) return real;
    }
    final passed = <LatLng>[];
    for (var i = 0; i < index; i++) {
      passed.addAll(_stepTrack(plan, i, route, chosen, now).$1);
    }
    final (pts, f) = _stepTrack(plan, index, route, chosen, _stepClock(plan, index, now));
    final upToNow = _prefix(pts, f);
    passed.addAll(upToNow);
    final dot = passed.isEmpty ? null : passed.last;
    // 방향: 지나온 길의 마지막 구간, 아직 출발 전이면 앞으로 갈 첫 구간
    double? heading;
    for (var i = passed.length - 1; i > 0 && heading == null; i--) {
      heading = _heading(passed[i - 1], passed[i]);
    }
    if (heading == null && dot != null) {
      for (final p in pts) {
        heading = _heading(dot, p);
        if (heading != null) break;
      }
    }
    return (dot: dot, heading: heading, passed: passed);
  }

  /// 지금 단계의 진행을 잴 시계. "탔어요" 같은 버튼을 계획보다 일찍 눌렀으면
  /// 누른 순간을 그 단계의 시작으로 봐서, 점이 그 구간의 처음부터 움직이기 시작해요 (11/14)
  DateTime _stepClock(TripPlan plan, int index, DateTime now) {
    final at = _manualAt;
    final start = plan.steps[index].start;
    if (index != _tripManualIndex || at == null || !at.isBefore(start)) return now;
    return now.add(start.difference(at));
  }

  /// 실제 모드: 지금 단계의 길 위에서 내 위치와 가장 가까운 곳까지를 지나온 길로 칠해요.
  /// 버튼으로 정한 단계를 따라요: "탔어요"를 눌렀으면 버스 노선 위에서 찾아요.
  /// 지금 단계의 길에서 많이 벗어나 있으면(책상에서 시험하거나 위치 오차가 클 때) null 을 돌려줘서
  /// 계획 시각 기준 추정으로 그려요. 그래야 "탔어요"를 누르면 시연 모드처럼 버스 구간을 따라 움직여요.
  ({LatLng? dot, double? heading, List<LatLng> passed})? _gpsTrack(
      TripPlan plan, int index, RouteCandidate route, StayEval? chosen, DateTime now, LatLng gps) {
    final before = <LatLng>[];
    for (var i = 0; i < index; i++) {
      before.addAll(_stepTrack(plan, i, route, chosen, now).$1);
    }
    final full = <LatLng>[];
    for (final p in _stepTrack(plan, index, route, chosen, now).$1) {
      if (full.isEmpty || full.last != p) full.add(p);
    }
    if (full.isEmpty) return null;
    if (full.length < 2) {
      // 가게에 있거나 정류장에서 기다리는 중: 가까이 있으면 실제 위치, 멀면 그 자리(추정)
      if (_meters(gps, full.first) > _gpsOnPathMeters) return null;
      return (dot: gps, heading: _gpsHeading, passed: [...before, full.first]);
    }
    // 경로의 각 구간에 내 위치를 수직으로 내려 가장 가까운 점을 찾아요
    final cos = math.cos(gps.latitude * math.pi / 180);
    var best = double.infinity, bestSeg = 0;
    LatLng bestPt = full.first;
    for (var i = 0; i + 1 < full.length; i++) {
      final a = full[i], b = full[i + 1];
      final ax = a.longitude * cos, ay = a.latitude, bx = b.longitude * cos, by = b.latitude;
      final px = gps.longitude * cos, py = gps.latitude;
      final len = (bx - ax) * (bx - ax) + (by - ay) * (by - ay);
      final t = len == 0 ? 0.0 : (((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / len).clamp(0.0, 1.0);
      final qx = ax + (bx - ax) * t, qy = ay + (by - ay) * t;
      final d = (px - qx) * (px - qx) + (py - qy) * (py - qy);
      if (d < best) {
        best = d;
        bestSeg = i;
        bestPt = LatLng(qy, qx / cos);
      }
    }
    if (_meters(gps, bestPt) > _gpsOnPathMeters) return null;
    final passed = [...before, ...full.take(bestSeg + 1), bestPt];
    final heading = _gpsHeading ?? _heading(full[bestSeg], full[bestSeg + 1]);
    return (dot: gps, heading: heading, passed: passed);
  }

  /// 지도 위에 이동 중 팝업을 얹어요. 이동 중이 아니면 지도만.
  Widget _withTripPanel({
    required TripPlan? trip,
    required int tripIndex,
    required RouteCandidate stripRoute,
    required Widget map,
  }) {
    if (trip == null) return KeyedSubtree(key: _mapKey, child: map);
    return Stack(key: _mapKey, children: [
      map,
      Positioned(
        left: 10,
        right: 10,
        bottom: 10,
        child: TripPanel(
          plan: trip,
          now: _tripClock,
          stepNow: _stepClock(trip, tripIndex, _tripClock),
          index: tripIndex,
          stripRoute: stripRoute,
          onAdvance: () => setState(() {
                _tripManualIndex = tripIndex + 1;
                _manualAt = _tripClock;
              }),
          onEnd: _endTrip,
          onSkip: widget.isDemo ? (m) => setState(() => _tripSkipMinutes += m) : null,
          onAsk: (text) async {
            // 질문하는 순간의 단계와 시각을 함께 보내요. 서버는 이 값으로 남은 시간·다음 차·늦어짐을 답해요
            final now = _tripClock;
            final phase = trip.steps[_tripIndex(trip)].phase;
            final res = await _askService.ask(text, trip: trip.toAskJson(phase, now));
            return _tripReply(res);
          },
        ),
      ),
    ]);
  }

  // ---------- 이동 중 AI 답변 버튼 (11/14) ----------
  // AI 탭을 없애서, AI 탭에 있던 버튼(#48 할 일·일정 초안, #50 경유지 추가)을 이동 중 팝업으로 옮겼어요.

  TripAskReply _tripReply(ServerAskResponse res) {
    if (res.needsConfirm) return TripAskReply(res.question ?? res.answer);
    final r = res.result ?? const <String, dynamic>{};
    final intent = r['intent']?.toString() ??
        (res.intents.isEmpty ? null : res.intents.first['intent']?.toString());
    final todo = res.todo;
    final savedId = widget.isDemo ? null : todo?['id'];

    // 1. 들를 수 있는 들르기: 서버가 할 일로 저장해 뒀어요 → 지금 경로에 경유지로 넣을지 물어봐요
    if (intent == 'stopover_check' && r['feasible'] == true && savedId != null) {
      return TripAskReply('${res.answer} 경유지로 추가할까요?', actions: [
        TripAskAction('경유지로 추가', Icons.add_location_alt_rounded, () => _addStopFromAsk('$savedId')),
      ]);
    }
    // 2. 시간이 부족한 들르기(실제 모드): 서버가 할 일 목록에 남겨 뒀어요
    if (intent == 'stopover_check' && r['feasible'] == false && savedId != null) {
      return TripAskReply('${res.answer} 할 일 목록에는 남겨 뒀어요.');
    }
    // 3. 저장 전 할 일 초안 ("나중에 ~해야 해", 시연 모드 들르기) → 버튼을 눌러야 넣어요
    if (todo != null && todo['id'] == null && (r['can_add_todo'] == true || intent == 'add_todo')) {
      return TripAskReply(res.answer, actions: [
        TripAskAction('할 일에 넣기', Icons.playlist_add_rounded, () => _addTodoFromAsk(todo)),
      ]);
    }
    // 4. 일정 추가 초안 → 일정 입력 화면
    final draft = ScheduleDraft.fromServerResult(r) ??
        (res.schedule != null ? ScheduleDraft.fromScheduleMap(res.schedule!) : null);
    if (intent == 'add_schedule' && draft != null) {
      return TripAskReply(res.answer, actions: [
        TripAskAction('일정 입력 열기', Icons.event_rounded, () => _openScheduleDraft(draft)),
      ]);
    }
    return TripAskReply(res.answer);
  }

  /// 서버가 저장한 할 일을 지금 이동의 경유지로 넣어요. 이미 넣은 곳이 있으면 같이 들러요 ('1+3').
  Future<String?> _addStopFromAsk(String id) async {
    await TodoScope.of(context).initialize();
    if (!mounted) return null;
    final trip = _trip;
    final current = activeRouteController.appliedFor(trip) ? activeRouteController.appliedTaskId : null;
    final ids = <String>{...?current?.split('+'), id};
    activeRouteController.setApplied(ids.join('+'), null, trip);
    activeRouteController.requestPlanRefresh();
    return '경유지에 넣었어요. 경로를 다시 계산할게요.';
  }

  Future<String?> _addTodoFromAsk(Map<String, dynamic> raw) async {
    final title = '${raw['text'] ?? ''}'.trim();
    if (title.isEmpty) return null;
    final controller = TodoScope.of(context);
    if (controller.todos.any((t) => t.title.trim() == title && !t.isCompleted)) {
      return '「$title」은(는) 이미 할 일에 있어요.';
    }
    final types = raw['place_types'] is List
        ? [for (final t in raw['place_types'] as List) '$t']
        : const <String>[];
    await controller.addTodo(
      title: title,
      minutes: (raw['stay_minutes'] as num?)?.toInt(),
      requiresTravel: types.isNotEmpty,
      placeTypes: types,
      important: raw['importance'] == '필수',
    );
    return '「$title」 할 일에 넣었어요.';
  }

  Future<String?> _openScheduleDraft(ScheduleDraft d) async {
    final saved = await Navigator.push<Schedule>(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          initial: Schedule(
            id: 0,
            title: d.title,
            location: d.location,
            startTime: d.start,
            endTime: d.end ?? d.start.add(const Duration(hours: 1)),
          ),
        ),
      ),
    );
    if (saved == null) return null;
    return '「${saved.title}」 일정을 추가했어요.';
  }

  /// 이 화면의 이동 (목적지 + 도착 시각)
  String get _trip => ActiveRouteController.tripKey(widget.destinationName, widget.arriveBy);

  /// 같은 이동에 적용해 둔 할 일이 있으면 이어서 써요 (11/13: 새로고침해도 적용이 풀리지 않게)
  void _restoreApplied() {
    if (!widget.isDemo && activeRouteController.appliedFor(_trip)) {
      _appliedTaskId = activeRouteController.appliedTaskId;
      _candidateId = activeRouteController.appliedCandidateId;
    } else {
      _appliedTaskId = null;
      _candidateId = null;
    }
    _lastSharedKey = _appliedTaskId == null ? null : '$_appliedTaskId|$_candidateId';
  }

  @override
  void initState() {
    super.initState();
    _restoreApplied();
  }

  @override
  void didUpdateWidget(covariant MoveRoutePlanner old) {
    super.didUpdateWidget(old);
    if (old.plan != widget.plan || old.routes.map((r) => r.id).join() != widget.routes.map((r) => r.id).join()) {
      final sameTrip = ActiveRouteController.tripKey(old.destinationName, old.arriveBy) == _trip;
      _restoreApplied();
      _needOverride.clear();
      if (!sameTrip) {
        _tripStarted = false;
        _stopTrip();
      }
    }
  }

  RouteCandidate get _selected =>
      widget.routes.firstWhere((r) => r.id == widget.selectedId, orElse: () => widget.routes.first);

  // ---------- 서버 계획과 경로 맞추기 ----------

  Map<String, dynamic>? _planRouteFor(RouteCandidate route) {
    final plan = widget.plan;
    if (plan == null) return null;
    // 순위(id)로 먼저 찾아요. 이름으로 먼저 찾으면 "2호선" 경로가 두 개일 때 2번 카드가 1번 경로 값을 써요 (11/13)
    for (final r in plan.routes) {
      if (route.id == 'server_${r['rank']}') return r;
    }
    for (final r in plan.routes) {
      final name = '${r['name'] ?? ''}'.trim();
      if (name.isNotEmpty && route.title.startsWith(name)) return r;
    }
    return null;
  }

  /// 서버가 탑승 시각·체류 시간까지 계산해 준 경로면 그 계획, 아니면 null
  DepartureOverview? _overviewFor(RouteCandidate route) {
    final r = _planRouteFor(route);
    final plan = widget.plan;
    if (r == null || plan == null) return null;
    final rank = (r['rank'] as num?)?.toInt() ?? 1;
    final data = Map<String, dynamic>.from(plan.data)..['routes'] = [r];
    if (r['depart_at'] != null) {
      // 11/13부터 서버가 경로마다 같은 기준으로 출발·탑승·도착 시각을 줘요.
      for (final key in ['basis', 'depart_at', 'board_at', 'arrive_at']) {
        data[key] = r[key];
      }
    } else if (rank != 1) {
      // 예전 서버: 탑승·도착 시각은 1순위 경로 기준이라 다른 순위에는 붙이지 않아요.
      data.remove('board_at');
      data.remove('arrive_at');
    }
    return DepartureOverview.fromPlan(
      ServerPlan(data),
      source: widget.isDemo ? DepartureSource.offlineDemo : DepartureSource.serverPlan,
      destination: widget.destinationName,
      fallbackArriveBy: widget.arriveBy,
      fallbackNeedMinutes: widget.fallbackNeed,
    );
  }

  /// 실시간 탑승 정보는 출발 30분 안일 때만 의미가 있어요 (팀 결정 11/13).
  static const int _realtimeWindow = 30;

  /// 경로 시각: 출발 시각 → 도착 시각, 도착 여유
  /// 서버 시각이 "지금 출발" 기준이라 도착 목표보다 한참 이르면(예: 내일 일정인데 오늘 08:30 도착),
  /// 도착 목표에서 거꾸로 계산해 "늦어도 몇 시에 나가면 몇 분 여유"로 다시 맞춰요.
  _RouteTimes _times(RouteCandidate route) {
    final t = _rawTimes(route);
    final target = widget.arriveBy;
    if (target == null) return t;
    final slack = target.difference(t.arrive).inMinutes;
    if (slack > _realtimeWindow + _departBuffer) {
      final dep = target.subtract(Duration(minutes: route.totalMinutes + _departBuffer));
      return _RouteTimes(dep, dep.add(Duration(minutes: route.totalMinutes)), true);
    }
    return t;
  }

  _RouteTimes _rawTimes(RouteCandidate route) {
    final r = _planRouteFor(route);
    final depart = DateTime.tryParse('${r?['depart_at'] ?? ''}');
    final arrive = DateTime.tryParse('${r?['arrive_at'] ?? ''}');
    if (depart != null && arrive != null) {
      // 서버 계산 그대로. 도착 시각에서 거꾸로 계산한 값이면 "(역산)" 표시
      return _RouteTimes(depart, arrive, r?['basis'] == 'arrive_by');
    }
    final o = _overviewFor(route);
    if (o != null && o.departure != null && o.arriveAt != null) {
      return _RouteTimes(o.departure!, o.arriveAt!, false);
    }
    final target = widget.arriveBy;
    if (target != null) {
      final dep = target.subtract(Duration(minutes: route.totalMinutes + _departBuffer));
      return _RouteTimes(dep, dep.add(Duration(minutes: route.totalMinutes)), true);
    }
    return _RouteTimes(widget.now, widget.now.add(Duration(minutes: route.totalMinutes)), true);
  }

  /// 할 일 목록은 계획 전체에 하나라서, 맞는 경로 아무거나에서 꺼내요.
  List<StayTask> get _tasks {
    for (final r in widget.routes) {
      final o = _overviewFor(r);
      if (o != null && o.tasks.isNotEmpty) return o.tasks;
    }
    return const [];
  }

  /// 적용한 할 일. 여러 개를 고르면('1+3') 한 번에 들르는 묶음이에요 (11/14).
  StayTask? get _applied {
    final id = _appliedTaskId;
    if (id == null) return null;
    for (final r in widget.routes) {
      final o = _overviewFor(r);
      if (o == null || o.tasks.isEmpty) continue;
      final t = o.taskFor(id, needOf: _needOf);
      if (t != null) return t;
    }
    return null;
  }

  int _needOf(StayTask t) => _needOverride[t.id] ?? t.needMinutes;

  /// 이 경로로 갈 때 [task]를 처리할 수 있는 가장 좋은 후보 판정 (계산 정보가 없으면 null)
  List<StayEval>? _evals(RouteCandidate route, StayTask task) {
    final o = _overviewFor(route);
    if (o == null || !o.canPlanStay) return null;
    final match = o.taskFor(task.id, needOf: _needOf);
    if (match == null) return null;
    return o.rank(match, delayMinutes: 0, need: _needOverride[task.id] ?? match.needMinutes);
  }

  /// 할 일을 적용했을 때 경로 카드 순서 (11/13)
  /// 그 할 일을 들를 수 있는 경로 → 빠른 경로. 단 가장 빠른 경로보다 15분 넘게 느리면 뒤로.
  /// 적용 전에는 받은 순서(빠른 순) 그대로예요.
  static const int _slowRouteLimit = 15;

  List<RouteCandidate> _orderedRoutes(StayTask? applied) {
    if (applied == null || widget.routes.length < 2) return widget.routes;
    final StayTask task = applied;
    final fastest = widget.routes.map((r) => r.totalMinutes).reduce((a, b) => a < b ? a : b);
    bool canDo(RouteCandidate r) {
      final e = _evals(r, task);
      return e != null && e.isNotEmpty && e.first.status != StayStatus.bad;
    }
    int key(RouteCandidate r) =>
        (r.totalMinutes > fastest + _slowRouteLimit ? 2 : 0) + (canDo(r) ? 0 : 1);
    final list = [...widget.routes];
    list.sort((a, b) {
      final k = key(a).compareTo(key(b));
      return k != 0 ? k : _shownTimes(a, task).minutes.compareTo(_shownTimes(b, task).minutes);
    });
    return list;
  }

  /// 카드·상세에 보여 줄 시각. 할 일을 적용했고 들를 수 있으면 경유지에 들렀다 가는 출발 시각이에요 (11/13).
  /// [chosen]은 선택한 경로에서 사용자가 고른 경유지 판정이에요.
  _RouteTimes _shownTimes(RouteCandidate r, StayTask? applied, {StayEval? chosen}) {
    final base = _times(r);
    if (applied == null) return base;
    final evals = chosen == null ? _evals(r, applied) : [chosen];
    if (evals == null || evals.isEmpty) return base;
    final e = evals.first;
    if (e.status == StayStatus.bad) return base;
    return _RouteTimes(e.depart, base.arrive, base.derived, true);
  }

  /// 카드 시간 띠에 쓸 경로. 할 일을 적용해 들를 수 있으면 처음 도보를
  /// "가게까지 도보 · 머무름 · 정류장까지 도보"로 바꿔서 아래 경유 상세와 같은 순서로 보여 줘요 (11/13)
  RouteCandidate _stripRoute(RouteCandidate r, StayTask? applied, {StayEval? chosen}) {
    if (applied == null || r.segments.isEmpty) return r;
    final evals = chosen == null ? _evals(r, applied) : [chosen];
    if (evals == null || evals.isEmpty) return r;
    final e = evals.first;
    if (e.status == StayStatus.bad) return r;
    final c = e.candidate;
    // 처음이 도보면 그 도보를 바꾸고, 정류장에서 시작하는 경로(시연)는 앞에 붙여요
    final first = r.segments.first;
    final startsWithWalk = first.type == RouteSegmentType.walking;
    return RouteCandidate(
      id: r.id,
      title: r.title,
      transferCount: r.transferCount,
      isRecommended: r.isRecommended,
      totalDurationMinutes: _shownTimes(r, applied, chosen: chosen).minutes,
      segments: [
        RouteSegment(type: RouteSegmentType.walking, description: '${c.name}까지 도보',
            durationMinutes: c.walkTo, startName: startsWithWalk ? first.startName : '출발지', endName: c.name),
        RouteSegment(type: RouteSegmentType.waiting, description: '${c.name}에서 머무름',
            durationMinutes: e.dwell, lineName: stayMarker, startName: c.name, endName: c.name),
        RouteSegment(type: RouteSegmentType.walking, description: '탑승 정류장까지 도보',
            durationMinutes: c.walkBack, startName: c.name, endName: startsWithWalk ? first.endName : first.startName),
        ...r.segments.skip(startsWithWalk ? 1 : 0),
      ],
    );
  }

  // ---------- 경로 카드 표시 (11/13: 지도앱 비교 반영) ----------

  /// 경로 특징 이름: 1번은 "최적", 나머지는 환승이 가장 적으면 "최소환승", 덜 걸으면 "덜 걷는 길"
  static int _walkMinutes(RouteCandidate r) => r.segments
      .where((s) => s.type == RouteSegmentType.walking)
      .fold(0, (sum, s) => sum + s.durationMinutes);

  String _badgeFor(int index, RouteCandidate r, List<RouteCandidate> all) {
    if (index == 0 || all.isEmpty) return '최적';
    final first = all.first;
    final minTransfers = all.map((x) => x.transferCount).reduce((a, b) => a < b ? a : b);
    if (r.transferCount == minTransfers && r.transferCount < first.transferCount) return '최소환승';
    final minWalk = all.map(_walkMinutes).reduce((a, b) => a < b ? a : b);
    final walk = _walkMinutes(r);
    if (walk == minWalk && walk < _walkMinutes(first)) return '덜 걷는 길';
    return '대안';
  }

  /// 요금 "1,550원" (서버가 준 값, 없으면 null)
  String? _fareOf(RouteCandidate r) {
    final fare = (_planRouteFor(r)?['fare'] as num?)?.toInt();
    if (fare == null || fare <= 0) return null;
    final digits = '$fare';
    final buf = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return '$buf원';
  }

  /// 계획한 뒤 지난 분 (실시간 "N분 뒤"를 지금 기준으로 맞춰요)
  int get _minutesSincePlan {
    final planned = DateTime.tryParse('${widget.plan?.data['now'] ?? ''}');
    if (planned == null || widget.isDemo) return 0;
    final m = DateTime.now().difference(planned).inMinutes;
    return m < 0 ? 0 : m;
  }

  /// 탈 정류장에 곧 오는 차 (지금 기준 분)와 그중 탈 차. 실시간이 없으면 빈 목록.
  ({String name, List<int> soon, int? board}) _liveOf(RouteCandidate r) {
    final p = _planRouteFor(r);
    final raw = p?['next_vehicles_min'];
    final passed = _minutesSincePlan;
    final soon = raw is List
        ? [for (final v in raw) if (v is num && v.toInt() - passed >= 0) v.toInt() - passed]
        : <int>[];
    final b = (p?['board_in_min'] as num?)?.toInt();
    final board = b == null || b - passed < 0 ? null : b - passed;
    return (name: '${p?['ride_name'] ?? ''}', soon: soon, board: board);
  }

  /// "실시간 · 2115번 2분 뒤 · 11분 뒤(탑승)"
  String? _liveText(RouteCandidate r) {
    final live = _liveOf(r);
    if (live.soon.isEmpty) return null;
    final parts = [for (final m in live.soon) m == live.board ? '$m분 뒤(탑승)' : '$m분 뒤'];
    // 앞 차들은 정류장까지 걷는 동안 지나가서 못 타면, 몇 분 뒤 차를 타는지 덧붙여요
    final board = live.board;
    final later = board != null && !live.soon.contains(board) ? ' → $board분 뒤 차 탑승' : '';
    return '실시간 · ${live.name.isEmpty ? '' : '${live.name} '}${parts.join(' · ')}$later';
  }

  /// 실시간 도착 정보가 없을 때: 서버 경로의 탑승 대기 시간 (11/14)
  String? _waitText(RouteCandidate r) {
    final w = (_planRouteFor(r)?['wait_min'] as num?)?.toInt();
    if (w == null || w <= 0) return null;
    return '정류장 대기 약 $w분 · 실시간 도착 정보는 출발 30분 전부터';
  }

  /// 적용한 할 일이 빠듯하거나 시간이 부족할 때: 다음 차를 타면 더 머물 수 있는지 (카카오맵 "여유"처럼)
  String? _nextVehicleHint(RouteCandidate r, List<StayEval>? stay) {
    if (stay == null || stay.isEmpty) return null;
    final e = stay.first;
    if (e.status == StayStatus.ok) return null;
    final live = _liveOf(r);
    final board = live.board;
    if (board == null) return null;
    final later = live.soon.where((m) => m > board);
    if (later.isEmpty) return null;
    final next = later.first;
    final extra = next - board;
    final dwell = (e.dwell < 0 ? 0 : e.dwell) + extra;
    final arrive = _times(r).arrive.add(Duration(minutes: extra));
    final arriveBy = widget.arriveBy;
    if (dwell < e.need || (arriveBy != null && arrive.isAfter(arriveBy))) return null;
    return '다음 차($next분 뒤)를 타면 ${e.candidate.name}에서 $dwell분 · ${KstTime.hm(arrive)} 도착';
  }

  /// 이 화면이 마지막으로 홈과 맞춘 값. 다른 화면(AI 질문)이 경유지를 바꾸면 그 값을 따라가요 (11/14).
  String? _lastSharedKey;

  /// 적용한 할 일·경유지를 홈과 함께 써요. 빌드 중에 알리면 안 돼서 화면을 그린 뒤에 알려요.
  void _shareApplied() {
    if (widget.isDemo) return;
    final trip = _trip;
    final ctrlKey = activeRouteController.appliedFor(trip)
        ? '${activeRouteController.appliedTaskId}|${activeRouteController.appliedCandidateId}'
        : null;
    final localKey = _appliedTaskId == null ? null : '$_appliedTaskId|$_candidateId';
    if (ctrlKey == localKey) {
      _lastSharedKey = localKey;
      return;
    }
    if (localKey != _lastSharedKey) {
      // 이 화면에서 바꿨어요 → 홈에 알려요
      _lastSharedKey = localKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) activeRouteController.setApplied(_appliedTaskId, _candidateId, trip);
      });
    } else {
      // 다른 화면에서 바꿨어요 → 이 화면이 따라가요
      _lastSharedKey = ctrlKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _appliedTaskId = activeRouteController.appliedFor(trip) ? activeRouteController.appliedTaskId : null;
          _candidateId = activeRouteController.appliedFor(trip) ? activeRouteController.appliedCandidateId : null;
        });
      });
    }
  }

  // ---------- 할 일 적용 창 ----------

  Future<void> _openTaskPicker() async {
    final tasks = _tasks;
    final feasible = <(StayTask, StayEval, bool)>[];
    var hidden = 0;
    for (final t in tasks) {
      StayEval? best;
      var early = false;
      for (final r in widget.routes) {
        final evals = _evals(r, t);
        if (evals == null || evals.isEmpty) continue;
        if (best == null || evals.first.maxDwell > best.maxDwell) {
          best = evals.first;
          early = _overviewFor(r)?.leaveEarlier ?? false;
        }
      }
      if (best != null && best.status != StayStatus.bad) {
        feasible.add((t, best, early));
      } else {
        hidden++;
      }
    }
    // 여러 곳을 고를 수 있어요 (11/14). 고른 순서가 아니라 걷는 시간이 짧은 순서로 묶어서 계산해요.
    final picked = <String>[
      for (final id in (_appliedTaskId ?? '').split('+'))
        if (feasible.any((f) => f.$1.id == id)) id,
    ];
    String? combinedLine() {
      if (picked.length < 2) return null;
      StayEval? best;
      for (final r in widget.routes) {
        final o = _overviewFor(r);
        final t = o?.taskFor(picked.join('+'), needOf: _needOf);
        if (o == null || t == null || !o.canPlanStay) continue;
        final e = o.rank(t, delayMinutes: 0, need: t.needMinutes);
        if (e.isNotEmpty && (best == null || e.first.maxDwell > best.maxDwell)) best = e.first;
      }
      if (best == null) return '이 조합은 계산할 수 없어요';
      final route = best.candidate.via.map((c) => c.name).join(' → ');
      return best.status == StayStatus.bad
          ? '${picked.length}곳 모두는 ${best.shortBy}분 부족해요 · $route'
          : '${picked.length}곳 모두 들를 수 있어요 · $route (${best.stayLabel})';
    }
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, setSheet) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('이번 이동에 들를 곳 선택', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('지금 경로 후보로 들를 수 있는 할 일만 보여 드려요.', style: TextStyle(color: AppTheme.textMuted)),
              const SizedBox(height: 12),
              if (widget.arriveBy != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(12)),
                  child: Text('도착 목표 ${KstTime.hm(widget.arriveBy)} · 들를 수 있는 시간은 경로마다 달라요',
                      style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 13)),
                ),
              const SizedBox(height: 8),
              if (feasible.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: Text(
                      tasks.isEmpty
                          ? '이 경로에서 계산할 수 있는 할 일이 없어요.\n할 일·일정 탭에서 들를 곳이 있는 할 일을 추가해 보세요.'
                          : '지금 도착 목표 안에 들를 수 있는 할 일이 없어요.\n일정이나 출발 시각을 바꿔 보세요.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: AppTheme.textMuted, height: 1.5),
                    ),
                  ),
                )
              else
                for (final (t, e, early) in feasible)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Material(
                      color: picked.contains(t.id) ? AppTheme.primarySoft : Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => setSheet(() {
                          if (!picked.remove(t.id)) picked.add(t.id);
                        }),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: picked.contains(t.id) ? AppTheme.primary : AppTheme.border, width: 2),
                          ),
                          child: Row(children: [
                            Icon(picked.contains(t.id) ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
                                color: AppTheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(t.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                                Text('필요 ${_needOf(t)}분 · ${e.candidate.name}',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                              ]),
                            ),
                            // 일정이 멀면: 몇 시에 나가면 들를 수 있는지 / 가까우면: 최대 몇 분 머물 수 있는지
                            if (early && e.latestDepart != null)
                              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text('${KstTime.hm(e.ample ? e.depart : e.latestDepart)} 출발',
                                    style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w800)),
                                Text(e.ample ? '들르기에 충분해요' : '이때 나가면 들를 수 있어요',
                                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                              ])
                            else
                              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                Text(e.stayLabel,
                                    style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w800)),
                                Text(e.ample ? '추천 ${e.dwell}분 머무르기' : '체류 가능',
                                    style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                              ]),
                          ]),
                        ),
                      ),
                    ),
                  ),
              if (hidden > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('시간이 부족한 할 일 $hidden개는 숨겼어요.',
                      style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                ),
              const SizedBox(height: 6),
              if (combinedLine() case final line?)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10)),
                  child: Text(line, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                )
              else
                const Text('여러 곳을 고르면 걷는 시간이 가장 짧은 순서로 묶어서 한 번에 계산해요.',
                    style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4)),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: picked.isEmpty ? null : () => Navigator.pop(sheet, picked.join('+')),
                  child: Text(picked.length > 1 ? '${picked.length}곳 들르는 경로 찾기' : '선택한 할 일로 경로 다시 찾기'),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(onPressed: () => Navigator.pop(sheet), child: const Text('취소')),
              ),
            ]),
          ),
        );
      }),
    );
    if (result == null || !mounted) return;
    // 카드 순서의 1번 경로(들를 수 있고 많이 느리지 않은 경로)로 바꿔 줘요.
    if (result.contains('+')) {
      final combined = _overviewFor(_selected)?.taskFor(result, needOf: _needOf) ??
          (() {
            for (final r in widget.routes) {
              final t = _overviewFor(r)?.taskFor(result, needOf: _needOf);
              if (t != null) return t;
            }
            return null;
          })();
      if (combined == null) return;
      final best = widget.routes.isEmpty ? null : _orderedRoutes(combined).first;
      setState(() {
        _appliedTaskId = result;
        _candidateId = null;
      });
      if (best != null && best.id != widget.selectedId) widget.onSelect(best.id);
      return;
    }
    final task = tasks.firstWhere((t) => t.id == result);
    // 병원인데 진료과가 없으면 먼저 물어봐요 (11/13). 진료과를 붙여 저장하면 경로를 다시 불러오고,
    // 같은 이동이라 적용한 할 일은 그대로 남아요.
    final todoScope = TodoScope.of(context);
    final matches = todoScope.todos.where((t) => '${t.id}' == task.id);
    final todo = matches.isEmpty ? null : matches.first;
    if (todo != null && needsSpecialty(todo.title, todo.placeTypes)) {
      final spec = await askSpecialty(context, todo.title);
      if (!mounted) return;
      if (spec != null && spec.isNotEmpty) {
        activeRouteController.setApplied(task.id, null, _trip);
        await todoScope.updateTodo(todo.copyWith(title: withSpecialty(todo.title, spec)));
        return;
      }
    }
    final RouteCandidate? bestRoute = widget.routes.isEmpty ? null : _orderedRoutes(task).first;
    setState(() {
      _appliedTaskId = result;
      _candidateId = null;
    });
    if (bestRoute != null && bestRoute.id != widget.selectedId) widget.onSelect(bestRoute.id);
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    final applied = _applied;
    final route = _selected;
    final evals = applied == null ? null : _evals(route, applied);
    final StayEval? chosenEval = evals == null || evals.isEmpty
        ? null
        : evals.firstWhere((e) => e.candidate.id == _candidateId, orElse: () => evals.first);
    final ordered = _orderedRoutes(applied);
    _shareApplied();
    final trip = _tripStarted ? _tripPlan(route, applied, chosenEval) : null;
    final tripIndex = trip == null ? 0 : _tripIndex(trip);
    _maybeAutoEnd(trip, tripIndex);
    final track = trip == null ? null : _tripTrack(trip, tripIndex, route, chosenEval);
    // 지도에 들를 수 있는 곳을 모두 보여 주고, 누르면 그곳으로 경로를 바꿔요 (11/13)
    final stopChoices = <StopChoice>[
      // 여러 곳을 들르면 두 번째 곳부터도 지도에 표시 (11/14)
      if (chosenEval != null && chosenEval.candidate.isMulti)
        for (var i = 1; i < chosenEval.candidate.via.length; i++)
          if (chosenEval.candidate.via[i].point != null)
            StopChoice(
              id: chosenEval.candidate.id,
              point: LatLng(chosenEval.candidate.via[i].point!.lat, chosenEval.candidate.via[i].point!.lng),
              label: '${i + 1}. ${chosenEval.candidate.via[i].name}',
              color: stayColor(chosenEval.status),
            ),
      for (final e in evals ?? const <StayEval>[])
        if (e.candidate.point != null && e.candidate.id != chosenEval?.candidate.id)
          StopChoice(
            id: e.candidate.id,
            point: LatLng(e.candidate.point!.lat, e.candidate.point!.lng),
            label: '${e.candidate.name} · ${e.status == StayStatus.bad ? '시간 부족' : e.stayLabel}',
            color: stayColor(e.status),
          ),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ① 제목
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                ),
                if (widget.badge != null) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(6)),
                    child: Text(widget.badge!,
                        style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w700)),
                  ),
                ],
              ]),
              const SizedBox(height: 2),
              Text(
                '${widget.originName} → ${widget.destinationName}'
                '${widget.arriveBy == null ? '' : ' · ${KstTime.hm(widget.arriveBy)} 도착 목표'}',
                maxLines: 2,
                style: const TextStyle(fontSize: 13, color: AppTheme.textMuted),
              ),
            ]),
          ),
          if (widget.onManageSchedule != null)
            OutlinedButton(
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 10)),
              onPressed: widget.onManageSchedule,
              child: const Text('일정 관리'),
            ),
        ]),
      ),
      const SizedBox(height: 12),

      // ② 지도 (이동 중이면 크게 + 지금 단계 팝업)
      _withTripPanel(
        trip: trip,
        tripIndex: tripIndex,
        stripRoute: _stripRoute(route, applied, chosen: chosenEval),
        map: RouteCompareMap(
        key: ValueKey('move-${widget.routes.map((r) => r.id).join(',')}'),
        routes: widget.routes,
        selectedId: route.id,
        onSelect: widget.onSelect,
        origin: widget.origin,
        destination: widget.destination,
        originName: widget.originName,
        destinationName: widget.destinationName,
        stopPoint: chosenEval?.candidate.point == null
            ? null
            : LatLng(chosenEval!.candidate.point!.lat, chosenEval.candidate.point!.lng),
        stopLabel: chosenEval?.candidate.name,
        stopChoices: stopChoices,
        onPickStop: (id) => setState(() => _candidateId = id),
        detourPath: chosenEval == null
            ? const []
            : [
                for (final p in [...chosenEval.candidate.pathTo, ...chosenEval.candidate.pathBack])
                  LatLng(p.lat, p.lng),
              ],
        liveDot: track?.dot,
        liveHeading: track?.heading,
        passedPath: track?.passed ?? const [],
        height: trip == null ? 260 : 560,
      ),
      ),
      if (stopChoices.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('지도에서 다른 곳(${stopChoices.length}곳)을 누르면 그곳에 들르는 걸로 바꿔요.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ),
      const SizedBox(height: 16),

      // ③ 추천 경로
      Row(children: [
        Text('추천 경로 ${widget.routes.length}개',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const Spacer(),
        // 실시간 정보는 금방 바뀌어서, 언제 계산한 값인지와 새로고침을 보여 줘요 (11/13)
        if (widget.plan != null && !widget.isDemo)
          Text('${KstTime.hm(widget.now)} 기준', style: const TextStyle(fontSize: 12, color: AppTheme.textMuted))
        else
          const Text('카드를 누르면 상세가 바뀌어요', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        if (widget.onRefresh != null && !widget.isDemo)
          IconButton(
            tooltip: '새로고침',
            visualDensity: VisualDensity.compact,
            onPressed: widget.onRefresh,
            icon: const Icon(Icons.refresh, size: 20),
          ),
      ]),
      const SizedBox(height: 8),
      for (var i = 0; i < ordered.length; i++)
        _RouteCard(
          index: i,
          route: ordered[i],
          times: _shownTimes(ordered[i], applied, chosen: ordered[i].id == route.id ? chosenEval : null),
          arriveBy: widget.arriveBy,
          selected: ordered[i].id == route.id,
          applied: applied,
          stay: applied == null ? null : _evals(ordered[i], applied),
          onTap: () => widget.onSelect(ordered[i].id),
          badge: _badgeFor(i, ordered[i], ordered),
          stripRoute: _stripRoute(ordered[i], applied, chosen: ordered[i].id == route.id ? chosenEval : null),
          fare: _fareOf(ordered[i]),
          live: _liveText(ordered[i]) ?? _waitText(ordered[i]),
          liveHint: applied == null ? null : _nextVehicleHint(ordered[i], _evals(ordered[i], applied)),
        ),

      // ④ 할 일 적용
      const SizedBox(height: 4),
      if (applied == null)
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Expanded(
              child: Text('아직 이번 이동에 적용한 할 일이 없어요.',
                  style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 12)),
              onPressed: _openTaskPicker,
              child: const Text('+ 할 일 적용하기'),
            ),
          ]),
        )
      else
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(color: AppTheme.okSoft, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            const Icon(Icons.check_circle_rounded, color: AppTheme.ok, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text('적용한 할 일: ${applied.title} (${_needOf(applied)}분)',
                  style: const TextStyle(color: AppTheme.ok, fontWeight: FontWeight.w700, fontSize: 13)),
            ),
            TextButton(onPressed: _openTaskPicker, child: const Text('변경')),
            TextButton(
              onPressed: () => setState(() {
                _appliedTaskId = null;
                _candidateId = null;
              }),
              child: const Text('빼기'),
            ),
          ]),
        ),

      // ⑤ 선택한 경로 상세
      const SizedBox(height: 18),
      const Text('선택한 경로 상세', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      _Metrics(times: _shownTimes(route, applied, chosen: chosenEval), arriveBy: widget.arriveBy),
      const SizedBox(height: 10),
      if (applied != null && chosenEval != null) ...[
        Row(children: [
          const Expanded(child: Text('경유지에서 머물 시간', style: TextStyle(color: AppTheme.textMuted))),
          IconButton(
            onPressed: _needOf(applied) > 1
                ? () => setState(() => _needOverride[applied.id] = _needOf(applied) - 1)
                : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Text('${_needOf(applied)}분', style: const TextStyle(fontWeight: FontWeight.w800)),
          IconButton(
            onPressed: () => setState(() => _needOverride[applied.id] = _needOf(applied) + 1),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ]),
        StayVerdictCard(
          overview: _overviewFor(route)!,
          eval: chosenEval,
          best: evals!.first,
          now: widget.now,
          originName: widget.originName,
          onSetNeed: (n) => setState(() => _needOverride[applied.id] = n),
          onPick: (c) => setState(() => _candidateId = c.id),
          rideSegments: route.segments,
        ),
      ] else ...[
        if (applied != null)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(color: AppTheme.warnSoft, borderRadius: BorderRadius.circular(12)),
            child: const Text('이 경로는 서버의 탑승·체류 계산이 없어 경유 시간을 알 수 없어요. 경유 최대 시간이 표시된 경로를 골라 주세요.',
                style: TextStyle(fontSize: 13, color: AppTheme.warn)),
          ),
        _Timeline(route: route, times: _times(route), originName: widget.originName, destinationName: widget.destinationName),
      ],

      // ⑥ 이동 시작
      const SizedBox(height: 14),
      FilledButton.icon(
        onPressed: () {
          if (chosenEval != null && chosenEval.status == StayStatus.bad) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('경유 시간이 부족해요. 머물 시간을 줄이거나 다른 경로를 골라 주세요.')));
            return;
          }
          if (_tripStarted) return _endTrip();
          setState(() {
            _tripStarted = true;
            _startTrip();
          });
        },
        icon: Icon(_tripStarted ? Icons.stop_circle_outlined : Icons.navigation_rounded),
        label: Text(_tripStarted ? '이동 종료' : '이 경로로 이동 시작'),
      ),
      if (_tripStarted) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
          decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            const Icon(Icons.circle, size: 10, color: AppTheme.ok),
            const SizedBox(width: 8),
            // AI 탭으로 넘어가지 않고 지도 위 팝업에서 바로 물어요 (#51 피드백 4)
            const Expanded(
              child: Text('이동 중 · 늦어지거나 궁금하면 지도 위 칸에 물어보세요 (말로도 돼요).',
                  style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        widget.isDemo
            ? '시연 데이터 기준이에요. 실시간 교통 정보가 아니에요.'
            : '"늦어도"가 붙은 시각은 도착 목표 5분 전에 닿도록 소요시간으로 거꾸로 계산한 값이에요. 실시간 버스 시각은 출발 30분 전부터 반영돼요.',
        style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
      ),
    ]);
  }
}

// ======================================================================

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.index,
    required this.route,
    required this.times,
    required this.arriveBy,
    required this.selected,
    required this.applied,
    required this.stay,
    required this.onTap,
    this.badge = '대안',
    this.fare,
    this.live,
    this.liveHint,
    this.stripRoute,
  });

  /// 시간 띠와 구간 글자에 쓸 경로 (할 일을 적용하면 경유 구간이 들어간 경로)
  final RouteCandidate? stripRoute;

  /// 최적 / 최소환승 / 덜 걷는 길 / 대안
  final String badge;
  /// "1,550원"
  final String? fare;
  /// "실시간 · 2115번 2분 뒤 · 11분 뒤(탑승)"
  final String? live;
  /// "다음 차(11분 뒤)를 타면 CU에서 9분 · 08:59 도착"
  final String? liveHint;
  final int index;
  final RouteCandidate route;
  final _RouteTimes times;
  final DateTime? arriveBy;
  final bool selected;
  final StayTask? applied;
  final List<StayEval>? stay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final slack = arriveBy?.difference(times.arrive).inMinutes;
    final String sideLabel;
    final String sideValue;
    Color sideColor = AppTheme.textStrong;
    if (applied != null) {
      sideLabel = '경유 가능';
      if (stay == null || stay!.isEmpty) {
        sideValue = '정보 없음';
        sideColor = AppTheme.textMuted;
      } else {
        final e = stay!.first;
        sideValue = e.dwell <= 0 ? '불가' : e.stayLabel;
        sideColor = stayColor(e.status);
      }
    } else {
      sideLabel = '도착 여유';
      sideValue = slack == null ? '-' : (slack >= 0 ? '$slack분' : '${-slack}분 늦음');
      sideColor = slack == null ? AppTheme.textMuted : (slack >= 0 ? AppTheme.ok : AppTheme.danger);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: selected ? const Color(0xFFFBFAFF) : Colors.white,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? AppTheme.primary : AppTheme.border, width: selected ? 2 : 1),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? AppTheme.primary : Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.primary, width: 2),
                  ),
                  child: Text('${index + 1}',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w800, color: selected ? Colors.white : AppTheme.primary)),
                ),
                const SizedBox(width: 8),
                Text(badge,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w800, color: index == 0 ? AppTheme.primary : AppTheme.textMuted)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(route.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppTheme.textMuted)),
                ),
              ]),
              const SizedBox(height: 6),
              Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${times.viaStop ? times.minutes : route.totalMinutes}분',
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                    Text(
                      '${times.viaStop ? '들러서 ' : (times.derived ? '늦어도 ' : '')}${KstTime.hm(times.depart)} 출발 → ${KstTime.hm(times.arrive)} 도착'
                      '${fare == null ? '' : ' · $fare'}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(sideLabel, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                  Text(sideValue, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: sideColor)),
                ]),
              ]),
              if (live != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.sensors, size: 14, color: AppTheme.ok),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(live!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.ok)),
                  ),
                ]),
              ],
              if (liveHint != null) ...[
                const SizedBox(height: 2),
                Text(liveHint!, style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(height: 10),
              RouteTimeStrip(route: stripRoute ?? route),
              const SizedBox(height: 4),
              Text(
                [
                  for (final s in (stripRoute ?? route).segments.where((s) => s.durationMinutes > 0 &&
                      (s.type != RouteSegmentType.waiting || s.lineName == stayMarker)))
                    s.lineName == stayMarker ? '머무름 ${s.durationMinutes}분' : '${_label(s)} ${s.durationMinutes}분',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

String _label(RouteSegment s) {
  final line = s.lineName?.trim();
  switch (s.type) {
    case RouteSegmentType.walking:
      return '도보';
    case RouteSegmentType.waiting:
      return '대기';
    case RouteSegmentType.bus:
      if (line != null && line.isNotEmpty) return line.endsWith('번') || line.contains('버스') ? line : '$line번';
      return '버스';
    case RouteSegmentType.subway:
      if (line != null && line.isNotEmpty) return line;
      final n = DemoRouteStyle.subwayNumber(s.description);
      return n == null ? '지하철' : '$n호선';
  }
}

class _Metrics extends StatelessWidget {
  const _Metrics({required this.times, required this.arriveBy});
  final _RouteTimes times;
  final DateTime? arriveBy;

  @override
  Widget build(BuildContext context) {
    final slack = arriveBy?.difference(times.arrive).inMinutes;
    Widget m(String label, String value, {Color? color}) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: color)),
            ]),
          ),
        );
    return Row(children: [
      m(times.viaStop ? '들러서 출발' : '추천 출발', KstTime.hm(times.depart)),
      const SizedBox(width: 8),
      m('예상 도착', KstTime.hm(times.arrive)),
      const SizedBox(width: 8),
      m('도착 여유', slack == null ? '-' : (slack >= 0 ? '$slack분' : '${-slack}분 늦음'),
          color: slack == null ? null : (slack >= 0 ? AppTheme.ok : AppTheme.danger)),
    ]);
  }
}

/// 할 일을 적용하지 않았을 때의 간단한 구간 안내
class _Timeline extends StatelessWidget {
  const _Timeline({required this.route, required this.times, required this.originName, required this.destinationName});
  final RouteCandidate route;
  final _RouteTimes times;
  final String originName;
  final String destinationName;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String, String, Color)>[];
    var t = times.depart;
    rows.add((KstTime.hm(t), '$originName 출발', '', AppTheme.textStrong));
    for (final s in route.segments) {
      if (s.durationMinutes <= 0) continue;
      final color = RouteCompareMap.segmentColor(s);
      final where = [s.startName, s.endName].whereType<String>().where((x) => x.trim().isNotEmpty).join(' → ');
      rows.add((KstTime.hm(t), '${_label(s)} ${s.durationMinutes}분', where, color));
      t = t.add(Duration(minutes: s.durationMinutes));
    }
    rows.add((KstTime.hm(times.arrive), '$destinationName 도착', '', AppTheme.textStrong));
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++)
          Stack(clipBehavior: Clip.none, children: [
            if (i < rows.length - 1)
              Positioned(
                left: 46 + 10 + 6,
                top: 15,
                bottom: -4,
                width: 2,
                child: Container(color: rows[i + 1].$4.withValues(alpha: 0.6)),
              ),
            Padding(
              padding: EdgeInsets.only(bottom: i == rows.length - 1 ? 0 : 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 46,
                  child: Text(rows[i].$1,
                      textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      border: Border.all(color: rows[i].$4, width: 3),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(rows[i].$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (rows[i].$3.isNotEmpty)
                      Text(rows[i].$3, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  ]),
                ),
              ]),
            ),
          ]),
        if (times.derived)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text('구간 시간은 경로 API 값이고, 대기·환승 대기는 포함되지 않았을 수 있어요.',
                style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ),
      ]),
    );
  }
}
