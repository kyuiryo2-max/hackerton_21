import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../config/api_config.dart';
import '../config/app_theme.dart';
import '../data/demo_route_options.dart';
import '../data/offline_demo_data.dart';
import '../models/departure_overview.dart';
import '../models/route_candidate.dart';
import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../providers/active_route_controller.dart';
import '../providers/schedule_controller.dart';
import '../providers/todo_controller.dart';
import '../services/departure_alert_service.dart';
import '../services/server_plan_service.dart';
import '../widgets/home/home_trip_map.dart';
import '../widgets/home/stay_planner_card.dart';
import '../widgets/open_on_phone.dart';
import 'detail_screen.dart';
import 'schedule_form_screen.dart';

/// 첫 화면 = 경유 판단 화면.
/// 지도 → 다음 일정 → 가는 길에 할 일 → 출발 시각 → "N분 머물 수 있어요" 판정 → 경유 후보 → 하단 출발 버튼
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onOpenRoutes,
    required this.onSelectWaypoint,
    this.onOpenScheduleRoutes,
    this.onOpenTab,
    this.onOpenAssistant,
    this.onChangeMode,
  });

  final VoidCallback onOpenRoutes;
  final ValueChanged<Schedule>? onOpenScheduleRoutes;
  final ValueChanged<TodoItem> onSelectWaypoint;
  final ValueChanged<int>? onOpenTab;
  /// 질문 문장을 넘기면 AI 화면에서 바로 물어봐요.
  final ValueChanged<String?>? onOpenAssistant;
  final VoidCallback? onChangeMode;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final DepartureAlertService _departureAlertService = DepartureAlertService();
  final ServerPlanService _planService = ServerPlanService();
  final TextEditingController _taskInput = TextEditingController();

  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  // 시연 계획 (서버 → 실패하면 앱 내장 예시)
  ServerPlan? _demoPlan;
  DepartureSource _demoSource = DepartureSource.serverDemo;
  bool _loadingPlan = false;
  DateTime _clockAnchor = DateTime.now();
  int _lastRevision = activeRouteController.revision;

  // 화면 선택 상태
  String? _overviewKey;
  String? _taskId;
  String? _candidateId;
  int? _delay; // 추천 출발 기준 몇 분 늦게 (음수 = 일찍)
  final Map<String, int> _needOverride = {};

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    activeRouteController.addListener(_onRouteChanged);
    if (ApiConfig.demoMode) {
      // 무료 서버가 깨어나는 동안에도 화면이 비지 않게 내장 예시를 먼저 보여 줘요.
      _demoPlan = ServerPlan(OfflineDemoData.plan);
      _demoSource = DepartureSource.offlineDemo;
    }
    _loadDemoPlan();
  }

  void _onRouteChanged() {
    _clockAnchor = DateTime.now();
    if (_lastRevision != activeRouteController.revision) {
      _lastRevision = activeRouteController.revision;
      _loadDemoPlan();
    }
  }

  Future<void> _loadDemoPlan() async {
    if (!ApiConfig.demoMode || _loadingPlan) return;
    _loadingPlan = true;
    if (mounted) setState(() {});
    ServerPlan plan;
    var source = DepartureSource.serverDemo;
    try {
      plan = await _planService.fetch();
    } catch (_) {
      plan = ServerPlan(OfflineDemoData.plan);
      source = DepartureSource.offlineDemo;
    }
    if (!mounted) return;
    setState(() {
      _demoPlan = plan;
      _demoSource = source;
      _clockAnchor = DateTime.now();
      _loadingPlan = false;
    });
  }

  Future<void> _refresh() async {
    setState(() => _now = DateTime.now());
    await _loadDemoPlan();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    activeRouteController.removeListener(_onRouteChanged);
    _planService.dispose();
    _taskInput.dispose();
    super.dispose();
  }

  // ---------- 데이터 정리 ----------

  String? _firstTransit(RouteCandidate route) {
    for (final leg in route.segments) {
      if (leg.type == RouteSegmentType.bus || leg.type == RouteSegmentType.subway) {
        final name = leg.lineName?.trim();
        if (name == null || name.isEmpty) return leg.type == RouteSegmentType.bus ? '버스' : '지하철';
        return leg.type == RouteSegmentType.bus && !name.endsWith('번') ? '$name번 버스' : name;
      }
    }
    return '도보';
  }

  GeoPoint? _routeOrigin(RouteCandidate route, String name) {
    for (final s in route.segments) {
      if (s.geometry.isNotEmpty) return GeoPoint(name, s.geometry.first.latitude, s.geometry.first.longitude);
    }
    return null;
  }

  GeoPoint? get _demoOrigin => GeoPoint.fromJson(OfflineDemoData.context['location']);

  int Function(String) _needFromTodos(List<TodoItem> todos) => (title) {
        for (final t in todos) {
          if (t.title == title && t.estimatedMinutes > 0) return t.estimatedMinutes;
        }
        return 5;
      };

  DepartureOverview? _resolveOverview(Schedule? next, List<TodoItem> todos) {
    final active = activeRouteController.active;
    if (active != null) {
      final plan = active.plan;
      if (plan != null) {
        return DepartureOverview.fromPlan(
          plan,
          source: ApiConfig.demoMode ? DepartureSource.serverDemo : DepartureSource.serverPlan,
          title: next?.title,
          destination: active.destination,
          fallbackPrepMinutes: next?.preparationMinutes,
          fallbackArriveBy: active.arrival,
          fallbackOrigin: _routeOrigin(active.selected, active.origin) ?? (ApiConfig.demoMode ? _demoOrigin : null),
          fallbackNeedMinutes: _needFromTodos(todos),
        );
      }
      final route = active.selected;
      final first = route.segments.where((s) =>
          s.type == RouteSegmentType.bus || s.type == RouteSegmentType.subway);
      return DepartureOverview(
        source: DepartureSource.selectedRoute,
        title: next?.title ?? '${active.destination} 가기',
        destination: active.destination,
        prepMinutes: next?.preparationMinutes ?? 30,
        departure: active.arrival.subtract(Duration(minutes: route.totalMinutes)),
        arriveBy: active.arrival,
        transitLabel: _firstTransit(route),
        boardStopName: first.isEmpty ? null : first.first.startName,
        totalMinutes: route.totalMinutes,
        origin: _routeOrigin(route, active.origin),
      );
    }
    final demo = _demoPlan;
    if (ApiConfig.demoMode && demo != null) {
      return DepartureOverview.fromPlan(
        demo,
        source: _demoSource,
        title: '청량리역 가기 · 시연 일정',
        fallbackOrigin: _demoOrigin,
        fallbackNeedMinutes: _needFromTodos(todos),
      );
    }
    if (next != null) {
      return DepartureOverview(
        source: DepartureSource.scheduleEstimate,
        title: next.title,
        destination: next.location,
        prepMinutes: next.preparationMinutes,
        departure: _departureAlertService.calculateDepartureTime(next.startTime),
        arriveBy: next.startTime,
        destinationPoint: next.destinationLatitude == null || next.destinationLongitude == null
            ? null
            : GeoPoint(next.location, next.destinationLatitude!, next.destinationLongitude!),
      );
    }
    return null;
  }

  List<LatLng> _routePath(DepartureOverview o) {
    final active = activeRouteController.active;
    if (active != null) {
      return [
        for (final s in active.selected.segments)
          if (s.type == RouteSegmentType.bus || s.type == RouteSegmentType.subway)
            for (final p in s.geometry) LatLng(p.latitude, p.longitude),
      ];
    }
    if (o.isDemo && o.routeName != null) {
      // 내장 카카오 경로 샘플 (실제 API 응답 좌표)
      for (final option in DemoRouteOptions.routes) {
        if (option.label.startsWith(o.routeName!)) {
          return [for (final leg in option.legs) if (leg.mode != 'WALKING') ...leg.path];
        }
      }
    }
    return const [];
  }

  DateTime _referenceNow(DepartureOverview? overview) {
    final demoNow = overview?.demoNow;
    if (demoNow == null) return _now;
    return demoNow.add(_now.difference(_clockAnchor));
  }

  /// 계획이 바뀌면 선택 상태를 처음으로 되돌려요.
  void _syncSelection(DepartureOverview o) {
    final key = '${o.source}|${o.departure}|${o.tasks.map((t) => '${t.id}:${t.candidates.length}').join(',')}';
    if (key == _overviewKey) return;
    _overviewKey = key;
    _taskId = o.tasks.isEmpty ? null : o.tasks.first.id;
    _candidateId = null;
    _delay = null;
    _needOverride.clear();
  }

  // ---------- 동작 ----------

  void _openSchedule(Schedule schedule) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => DetailScreen(
          title: schedule.title,
          schedule: schedule,
          onOpenScheduleRoutes: widget.onOpenScheduleRoutes,
        ),
      ),
    ).then((_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  Future<void> _addSchedule() async {
    final saved = await Navigator.push<Schedule>(
      context,
      MaterialPageRoute(builder: (_) => const ScheduleFormScreen()),
    );
    if (saved != null && mounted) widget.onOpenScheduleRoutes?.call(saved);
  }

  /// 새 할 일은 AI에게 "들렀다 가도 돼?"로 물어봐요 (질문 종류 stopover_check → 서버가 장소·시간 계산).
  void _askStopover() {
    final text = _taskInput.text.trim();
    if (text.isEmpty) return;
    FocusScope.of(context).unfocus();
    _taskInput.clear();
    final question = text.contains('?') || text.endsWith('돼') ? text : '가는 길에 $text 들렀다 가도 돼?';
    widget.onOpenAssistant?.call(question);
  }

  static const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

  String _dateLabel(DateTime kstOrLocal) =>
      '${kstOrLocal.month}월 ${kstOrLocal.day}일 ${_weekdays[kstOrLocal.weekday - 1]}요일';

  static String _countdown(Duration d) {
    final total = (d.inSeconds / 60).ceil();
    if (total <= 0) return '0분';
    final h = total ~/ 60, m = total % 60;
    if (h == 0) return '$m분';
    return m == 0 ? '$h시간' : '$h시간 $m분';
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final schedules = ScheduleScope.of(context).schedules;
    final todos = TodoScope.of(context).todos;

    final upcoming = schedules
        .where((s) => !s.isCompleted && s.startTime.isAfter(_now))
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final next = upcoming.isEmpty ? null : upcoming.first;
    final today = schedules
        .where((s) => s.startTime.year == _now.year && s.startTime.month == _now.month && s.startTime.day == _now.day)
        .toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));

    return AnimatedBuilder(
      animation: activeRouteController,
      builder: (context, _) {
        final overview = _resolveOverview(next, todos);
        final refNow = _referenceNow(overview);
        final plan = overview != null && overview.canPlanStay && overview.tasks.isNotEmpty
            ? _StayView.build(this, overview, refNow)
            : null;

        return Scaffold(
          bottomNavigationBar: plan == null ? null : _Cta(view: plan, onTap: widget.onOpenRoutes),
          body: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              key: const PageStorageKey('home-scroll'),
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                _TopBar(
                  sub: overview?.demoNow != null
                      ? '${_dateLabel(refNow.toUtc().add(const Duration(hours: 9)))} · 시연 시각 ${hm(refNow)}'
                      : '${_dateLabel(_now)} · ${hm(_now)}',
                  isDemo: ApiConfig.demoMode,
                  onChangeMode: widget.onChangeMode,
                ),
                if (overview != null && (overview.origin != null || overview.destinationPoint != null))
                  HomeTripMap(
                    overview: overview,
                    evals: plan?.evals ?? const [],
                    selectedId: plan?.selected.candidate.id,
                    routePath: _routePath(overview),
                    onPick: (c) => setState(() => _candidateId = c.id),
                  )
                else
                  const SizedBox(height: 18),
                Transform.translate(
                  offset: const Offset(0, -18),
                  child: Container(
                    decoration: const BoxDecoration(
                      color: AppTheme.background,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
                      boxShadow: [BoxShadow(color: Color(0x1A14181C), blurRadius: 30, offset: Offset(0, -10))],
                    ),
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 120),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(color: AppTheme.border, borderRadius: BorderRadius.circular(2)),
                        ),
                      ),
                      if (overview == null)
                        _loadingPlan
                            ? const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
                            : _EmptyTrip(onAddSchedule: _addSchedule, onOpenRoutes: widget.onOpenRoutes)
                      else
                        _TripCard(
                          overview: overview,
                          now: refNow,
                          countdown: _countdown,
                          onOpenRoutes: widget.onOpenRoutes,
                        ),
                      if (plan != null) ..._stayBlocks(plan)
                      else if (overview != null) ...[
                        const SizedBox(height: 16),
                        _StayHintCard(onOpenRoutes: widget.onOpenRoutes),
                      ],
                      const SizedBox(height: 26),
                      _SectionTitle(title: '오늘 일정', actionLabel: '전체', onAction: () => widget.onOpenTab?.call(1)),
                      _TodaySchedules(schedules: today, now: _now, onTap: _openSchedule, onAdd: _addSchedule),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _stayBlocks(_StayView v) {
    final o = v.overview;
    final ok = v.evals.where((e) => e.status != StayStatus.bad).length;
    return [
      const SizedBox(height: 22),
      // 가는 길에 할 일
      const _H2('가는 길에 할 일'),
      Container(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(children: [
          const Icon(Icons.search_rounded, size: 20, color: AppTheme.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _taskInput,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _askStopover(),
              decoration: const InputDecoration(
                hintText: '예: 약 사기, 우유 사기, 서류 출력',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.textStrong,
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: _askStopover,
            child: const Text('AI에게 묻기', style: TextStyle(fontSize: 13)),
          ),
        ]),
      ),
      const SizedBox(height: 10),
      SizedBox(
        height: 36,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          for (final t in o.tasks)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                showCheckmark: false,
                label: Text(t.isRequired ? '${t.title} · 필수' : t.title),
                selected: t.id == v.task.id,
                selectedColor: AppTheme.primarySoft,
                labelStyle: TextStyle(
                  fontSize: 13,
                  color: t.id == v.task.id ? AppTheme.primary : AppTheme.textMuted,
                  fontWeight: t.id == v.task.id ? FontWeight.w700 : FontWeight.w500,
                ),
                side: BorderSide(color: t.id == v.task.id ? AppTheme.primary : AppTheme.border),
                onSelected: (_) => setState(() {
                  _taskId = t.id;
                  _candidateId = null;
                }),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Text(
            v.task.needFromServer || _needOverride.containsKey(v.task.id) ? '머물러야 하는 시간' : '머물러야 하는 시간 (기본값)',
            style: const TextStyle(color: AppTheme.textMuted),
          ),
        ),
        _Stepper(
          value: v.need,
          onChanged: (n) => setState(() => _needOverride[v.task.id] = n.clamp(1, 90).toInt()),
        ),
      ]),

      // 출발 시각
      const SizedBox(height: 24),
      Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
        const Expanded(child: _H2('출발 시각', bottom: 0)),
        if (v.delay == 0)
          const Padding(
            padding: EdgeInsets.only(right: 6),
            child: Text('추천', style: TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w700)),
          ),
        Text(hm(v.eval.depart), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
      ]),
      Slider(
        value: v.delay.toDouble(),
        min: v.lo.toDouble(),
        max: v.hi.toDouble(),
        divisions: v.hi - v.lo,
        label: '${hm(o.departure!.add(Duration(minutes: v.delay)))} 출발',
        onChanged: (x) => setState(() => _delay = x.round()),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Text(v.loIsNow ? '지금 ${hm(o.departure!.add(Duration(minutes: v.lo)))}' : hm(o.departure!.add(Duration(minutes: v.lo))),
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
          const Spacer(),
          if (v.lo <= 0 && v.delay != 0)
            GestureDetector(
              onTap: () => setState(() => _delay = 0),
              child: Text('추천 ${hm(o.departure)}로',
                  style: const TextStyle(fontSize: 12, color: AppTheme.primary, fontWeight: FontWeight.w700)),
            ),
          const Spacer(),
          Text(hm(o.departure!.add(Duration(minutes: v.hi))), style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
        ]),
      ),

      // 판정
      const SizedBox(height: 18),
      StayVerdictCard(
        overview: o,
        eval: v.eval,
        best: v.evals.isEmpty ? null : v.evals.first,
        now: v.now,
        originName: o.origin?.name,
        onSetDelay: (d) => setState(() => _delay = d.clamp(v.lo, v.hi).toInt()),
        onSetNeed: (n) => setState(() => _needOverride[v.task.id] = n.clamp(1, 90).toInt()),
        onPick: (c) => setState(() => _candidateId = c.id),
      ),

      // 후보
      const SizedBox(height: 22),
      Row(children: [
        const Expanded(child: _H2('경유 후보', bottom: 0)),
        Text('${v.evals.length}곳 중 $ok곳 가능', style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      ]),
      const SizedBox(height: 10),
      for (var i = 0; i < v.evals.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: StayCandidateTile(
            index: i + 1,
            eval: v.evals[i],
            overview: o,
            selected: v.evals[i].candidate.id == v.selected.candidate.id,
            onTap: () => setState(() => _candidateId = v.evals[i].candidate.id),
          ),
        ),
      if (v.task.reason.isNotEmpty && v.task.serverStatus != '포함')
        Text('서버 판단: ${v.task.serverStatus} · ${v.task.reason}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      const SizedBox(height: 14),
      Text(
        [
          switch (o.source) {
            DepartureSource.offlineDemo => '앱에 들어 있는 시연 예시로 계산했어요. 실시간 정보가 아니에요.',
            DepartureSource.serverDemo => '서버 시연 데이터로 계산했어요. 실시간 정보가 아니에요.',
            _ => '서버가 계산한 탑승 시각과 도보 시간 기준이에요.',
          },
          '출발 시각을 바꿔도 서버를 다시 부르지 않고 화면에서만 다시 계산해요.',
          if (v.evals.any((e) => e.candidate.walkSplitEstimated)) '편도 도보는 왕복 시간을 반으로 나눈 추정치예요.',
        ].join(' '),
        style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.6),
      ),
    ];
  }
}

/// 지금 선택 상태로 계산한 판정 묶음.
class _StayView {
  _StayView({
    required this.overview,
    required this.task,
    required this.need,
    required this.delay,
    required this.lo,
    required this.hi,
    required this.loIsNow,
    required this.evals,
    required this.selected,
    required this.now,
  });

  final DepartureOverview overview;
  final StayTask task;
  final int need;
  final int delay;
  final int lo;
  final int hi;
  final bool loIsNow;
  final List<StayEval> evals;
  final StayEval selected;
  final DateTime now;

  StayEval get eval => selected;

  static _StayView build(_HomeScreenState s, DepartureOverview o, DateTime now) {
    s._syncSelection(o);
    final task = o.tasks.firstWhere((t) => t.id == s._taskId, orElse: () => o.tasks.first);
    final need = s._needOverride[task.id] ?? task.needMinutes;

    // 슬라이더 범위: 지금(또는 추천 10분 전) ~ 여유가 다 떨어지고 조금 더
    final nowDelay = (now.difference(o.departure!).inSeconds / 60).ceil();
    var lo = -10;
    var loIsNow = false;
    if (nowDelay > lo) {
      lo = nowDelay;
      loIsNow = true;
    }
    final spare = o.spareMinutes ?? 0;
    var hi = spare + 5;
    if (hi < lo + 10) hi = lo + 10;
    final delay = (s._delay ?? (lo > 0 ? lo : 0)).clamp(lo, hi).toInt();

    final evals = o.rank(task, delayMinutes: delay, need: need);
    final selected = evals.firstWhere((e) => e.candidate.id == s._candidateId, orElse: () => evals.first);
    return _StayView(
      overview: o,
      task: task,
      need: need,
      delay: delay,
      lo: lo,
      hi: hi,
      loIsNow: loIsNow,
      evals: evals,
      selected: selected,
      now: now,
    );
  }
}

// ======================================================================
// 작은 위젯들
// ======================================================================

class _H2 extends StatelessWidget {
  const _H2(this.text, {this.bottom = 10});
  final String text;
  final double bottom;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: -0.2)),
      );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.sub, required this.isDemo, this.onChangeMode});
  final String sub;
  final bool isDemo;
  final VoidCallback? onChangeMode;

  @override
  Widget build(BuildContext context) {
    final tone = isDemo ? AppTheme.warn : AppTheme.primary;
    return Container(
      color: Colors.white,
      child: SafeArea(
        bottom: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
          child: Row(children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(9)),
              child: const Icon(Icons.alt_route_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Sync_ro', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: -0.3)),
                Text(sub, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
              ]),
            ),
            const OpenOnPhoneButton(),
            Material(
              color: isDemo ? AppTheme.warnSoft : AppTheme.primarySoft,
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: onChangeMode,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(isDemo ? Icons.science_outlined : Icons.person_outline, size: 15, color: tone),
                    const SizedBox(width: 4),
                    Text(isDemo ? '시연 모드' : '실제 모드',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tone)),
                    Icon(Icons.expand_more_rounded, size: 15, color: tone),
                  ]),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({required this.overview, required this.now, required this.countdown, required this.onOpenRoutes});
  final DepartureOverview overview;
  final DateTime now;
  final String Function(Duration) countdown;
  final VoidCallback onOpenRoutes;

  (String, Color) _status() {
    final o = overview;
    final dep = o.departure;
    if (dep == null) return ('출발 시각을 계산하지 못했어요', AppTheme.textMuted);
    final prep = o.prepStart;
    if (prep != null && now.isBefore(prep)) return ('준비 시작까지 ${countdown(prep.difference(now))}', AppTheme.primary);
    if (now.isBefore(dep)) return ('출발까지 ${countdown(dep.difference(now))} · 지금 준비하세요', AppTheme.warn);
    final board = o.boardAt;
    if (board != null && now.isBefore(board)) {
      return ('지금 나가세요 · ${o.transitLabel ?? '탑승'}까지 ${countdown(board.difference(now))}', AppTheme.warn);
    }
    final late = now.difference(dep).inMinutes;
    if (late <= 1) return ('지금 나가세요', AppTheme.warn);
    return ('추천 출발이 $late분 지났어요', AppTheme.danger);
  }

  String get _badge => switch (overview.source) {
        DepartureSource.serverDemo => '시연 · 서버',
        DepartureSource.offlineDemo => '시연 · 예시',
        DepartureSource.serverPlan => '서버 계산',
        DepartureSource.selectedRoute => '선택한 경로',
        DepartureSource.scheduleEstimate => '임시 추정',
      };

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final (status, tone) = _status();
    Widget od({required bool dest, required String label, required String value, required String muted}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            SizedBox(
              width: 16,
              child: Center(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: dest ? AppTheme.textStrong : Colors.white,
                    shape: dest ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius: dest ? BorderRadius.circular(3) : null,
                    border: Border.all(color: AppTheme.textStrong, width: 3),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 30, child: Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted))),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(text: '  $muted', style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Text('다음 일정', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(6)),
                  child: Text(_badge, style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w700)),
                ),
              ]),
              const SizedBox(height: 2),
              Text(o.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(hm(o.arriveBy), style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.8, height: 1)),
            const Text('도착 목표', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ]),
        ]),
        const SizedBox(height: 10),
        Stack(children: [
          Positioned(left: 7, top: 16, bottom: 16, child: Container(width: 2, color: AppTheme.border)),
          Column(children: [
            od(dest: false, label: '출발', value: o.origin?.name ?? '현재 위치', muted: o.origin == null ? '' : '현재 위치'),
            od(dest: true, label: '도착', value: o.destination, muted: '일정 장소'),
          ]),
        ]),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('추천 출발', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
              Text(hm(o.departure), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
            ]),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(status, style: TextStyle(fontWeight: FontWeight.w800, color: tone, fontSize: 13)),
                Text(
                  o.isEstimate
                      ? '이동 35분 + 여유 10분 임시 계산 · 준비 ${hm(o.prepStart)}부터'
                      : '준비 ${hm(o.prepStart)}부터 · ${o.transitLabel ?? '대중교통'} ${hm(o.boardAt)} 탑승',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ]),
            ),
            IconButton(
              tooltip: '이동 탭에서 경로 보기',
              onPressed: onOpenRoutes,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ]),
        ),
      ]),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.value, required this.onChanged});
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AppTheme.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '1분 줄이기',
            onPressed: value > 1 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_rounded, size: 18),
          ),
          SizedBox(
            width: 44,
            child: Text('$value분', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: '1분 늘리기',
            onPressed: value < 90 ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_rounded, size: 18),
          ),
        ]),
      );
}

class _Cta extends StatelessWidget {
  const _Cta({required this.view, required this.onTap});
  final _StayView view;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = view.selected;
    final bad = e.status == StayStatus.bad;
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [AppTheme.background, AppTheme.background, Color(0x00F5F5FA)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: SafeArea(
        top: false,
        child: FilledButton(
          onPressed: onTap,
          child: Text(
            bad ? '바로 ${view.overview.destination}(으)로 출발' : '${e.candidate.name} 들렀다 출발',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _EmptyTrip extends StatelessWidget {
  const _EmptyTrip({required this.onAddSchedule, required this.onOpenRoutes});
  final VoidCallback onAddSchedule;
  final VoidCallback onOpenRoutes;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppTheme.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.event_available_rounded, color: AppTheme.primary, size: 28),
          const SizedBox(height: 10),
          const Text('다가오는 일정이 없어요', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('일정을 추가하면 언제 나가야 하는지, 들를 곳에서 얼마나 머물 수 있는지 알려 드려요.',
              style: TextStyle(color: AppTheme.textMuted, height: 1.4)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: onAddSchedule,
                icon: const Icon(Icons.add_rounded),
                label: const Text('일정 추가'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onOpenRoutes, child: const Text('경로만 찾기')),
          ]),
        ]),
      );
}

class _StayHintCard extends StatelessWidget {
  const _StayHintCard({required this.onOpenRoutes});
  final VoidCallback onOpenRoutes;

  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.hourglass_bottom_rounded, color: AppTheme.primary, size: 20),
          ),
          title: const Text('들를 곳에서 몇 분 머물 수 있는지 볼까요?', style: TextStyle(fontWeight: FontWeight.w700)),
          subtitle: const Text('이동 탭에서 경로를 고르면 출발 시각별로 계산해 드려요.'),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: onOpenRoutes,
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.actionLabel, this.onAction});
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Expanded(child: _H2(title, bottom: 0)),
          if (actionLabel != null && onAction != null) TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ]),
      );
}

class _TodaySchedules extends StatelessWidget {
  const _TodaySchedules({required this.schedules, required this.now, required this.onTap, required this.onAdd});
  final List<Schedule> schedules;
  final DateTime now;
  final ValueChanged<Schedule> onTap;
  final VoidCallback onAdd;

  static String _hm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (schedules.isEmpty) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.event_note_outlined),
          title: const Text('오늘 등록된 일정이 없어요'),
          trailing: TextButton(onPressed: onAdd, child: const Text('추가')),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < schedules.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 76),
          InkWell(
            onTap: () => onTap(schedules[i]),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Row(children: [
                SizedBox(
                  width: 48,
                  child: Text(_hm(schedules[i].startTime),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: schedules[i].startTime.isBefore(now) ? AppTheme.textMuted : AppTheme.primary,
                      )),
                ),
                Container(
                  width: 3,
                  height: 34,
                  margin: const EdgeInsets.only(right: 12),
                  decoration: BoxDecoration(
                    color: schedules[i].isCompleted || schedules[i].startTime.isBefore(now)
                        ? AppTheme.border
                        : AppTheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(schedules[i].title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          decoration: schedules[i].isCompleted ? TextDecoration.lineThrough : null,
                        )),
                    Text(schedules[i].location,
                        overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
                const Icon(Icons.chevron_right_rounded, color: AppTheme.textMuted),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}
