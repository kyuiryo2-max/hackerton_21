import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../config/app_theme.dart';
import '../data/demo_route_style.dart';
import '../models/departure_overview.dart';
import '../models/route_candidate.dart';
import '../services/kst_time.dart';
import '../services/server_plan_service.dart';
import 'home/stay_planner_card.dart';
import 'route_compare_map.dart';

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

  @override
  State<MoveRoutePlanner> createState() => _MoveRoutePlannerState();
}

/// 경로 한 개의 시각
class _RouteTimes {
  const _RouteTimes(this.depart, this.arrive, this.derived);
  final DateTime depart;
  final DateTime arrive;
  /// 실시간·시간표 없이 소요시간으로 역산한 값
  final bool derived;
}

class _MoveRoutePlannerState extends State<MoveRoutePlanner> {
  static const int _departBuffer = 5; // 정류장에 미리 도착해 있는 여유 (서버 timecalc 와 같은 값)

  String? _appliedTaskId;
  String? _candidateId;
  final Map<String, int> _needOverride = {};
  bool _tripStarted = false;

  @override
  void didUpdateWidget(covariant MoveRoutePlanner old) {
    super.didUpdateWidget(old);
    if (old.plan != widget.plan || old.routes.map((r) => r.id).join() != widget.routes.map((r) => r.id).join()) {
      _appliedTaskId = null;
      _candidateId = null;
      _needOverride.clear();
      _tripStarted = false;
    }
  }

  RouteCandidate get _selected =>
      widget.routes.firstWhere((r) => r.id == widget.selectedId, orElse: () => widget.routes.first);

  // ---------- 서버 계획과 경로 맞추기 ----------

  Map<String, dynamic>? _planRouteFor(RouteCandidate route) {
    final plan = widget.plan;
    if (plan == null) return null;
    for (final r in plan.routes) {
      final name = '${r['name'] ?? ''}'.trim();
      if (route.id == 'server_${r['rank']}' || (name.isNotEmpty && route.title.startsWith(name))) return r;
    }
    return null;
  }

  /// 서버가 탑승 시각·체류 시간까지 계산해 준 경로면 그 계획, 아니면 null
  DepartureOverview? _overviewFor(RouteCandidate route) {
    final r = _planRouteFor(route);
    final plan = widget.plan;
    if (r == null || plan == null) return null;
    // 탑승·도착 시각은 1순위 경로 기준이라 다른 순위에는 붙이지 않아요.
    final rank = (r['rank'] as num?)?.toInt() ?? 1;
    final data = Map<String, dynamic>.from(plan.data)..['routes'] = [r];
    if (rank != 1) {
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

  _RouteTimes _times(RouteCandidate route) {
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

  StayTask? get _applied {
    for (final t in _tasks) {
      if (t.id == _appliedTaskId) return t;
    }
    return null;
  }

  int _needOf(StayTask t) => _needOverride[t.id] ?? t.needMinutes;

  /// 이 경로로 갈 때 [task]를 처리할 수 있는 가장 좋은 후보 판정 (계산 정보가 없으면 null)
  List<StayEval>? _evals(RouteCandidate route, StayTask task) {
    final o = _overviewFor(route);
    if (o == null || !o.canPlanStay) return null;
    final match = o.tasks.where((t) => t.id == task.id);
    if (match.isEmpty) return null;
    return o.rank(match.first, delayMinutes: 0, need: _needOf(task));
  }

  // ---------- 할 일 적용 창 ----------

  Future<void> _openTaskPicker() async {
    final tasks = _tasks;
    final feasible = <(StayTask, StayEval)>[];
    var hidden = 0;
    for (final t in tasks) {
      StayEval? best;
      for (final r in widget.routes) {
        final evals = _evals(r, t);
        if (evals == null || evals.isEmpty) continue;
        if (best == null || evals.first.dwell > best.dwell) best = evals.first;
      }
      if (best != null && best.status != StayStatus.bad) {
        feasible.add((t, best));
      } else {
        hidden++;
      }
    }
    String? chosen = _appliedTaskId;
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
                for (final (t, e) in feasible)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Material(
                      color: chosen == t.id ? AppTheme.primarySoft : Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => setSheet(() => chosen = t.id),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: chosen == t.id ? AppTheme.primary : AppTheme.border, width: 2),
                          ),
                          child: Row(children: [
                            Icon(chosen == t.id ? Icons.radio_button_checked : Icons.radio_button_off,
                                color: AppTheme.primary),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(t.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                                Text('필요 ${_needOf(t)}분 · ${e.candidate.name}',
                                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                              ]),
                            ),
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text('최대 ${e.dwell}분',
                                  style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w800)),
                              const Text('체류 가능', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
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
              const Text('한 번에 한 곳만 적용해요. 여러 곳을 들르려면 경로를 다시 확인해야 해서, 먼저 한 곳으로 계산해요.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textMuted, height: 1.4)),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: chosen == null ? null : () => Navigator.pop(sheet, chosen),
                  child: const Text('선택한 할 일로 경로 다시 찾기'),
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
    // 들를 수 있는 시간이 가장 긴 경로로 바꿔 줘요.
    final task = tasks.firstWhere((t) => t.id == result);
    RouteCandidate? bestRoute;
    var bestDwell = -1 << 30;
    for (final r in widget.routes) {
      final evals = _evals(r, task);
      if (evals == null || evals.isEmpty) continue;
      if (evals.first.dwell > bestDwell) {
        bestDwell = evals.first.dwell;
        bestRoute = r;
      }
    }
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

      // ② 지도
      RouteCompareMap(
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
        height: 260,
      ),
      const SizedBox(height: 16),

      // ③ 추천 경로
      Row(children: [
        Text('추천 경로 ${widget.routes.length}개',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const Spacer(),
        const Text('카드를 누르면 상세가 바뀌어요', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
      ]),
      const SizedBox(height: 8),
      for (var i = 0; i < widget.routes.length; i++)
        _RouteCard(
          index: i,
          route: widget.routes[i],
          times: _times(widget.routes[i]),
          arriveBy: widget.arriveBy,
          selected: widget.routes[i].id == route.id,
          applied: applied,
          stay: applied == null ? null : _evals(widget.routes[i], applied),
          onTap: () => widget.onSelect(widget.routes[i].id),
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
      _Metrics(times: _times(route), arriveBy: widget.arriveBy),
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
          setState(() => _tripStarted = !_tripStarted);
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
            const Expanded(
              child: Text('이동 중 · 경유지 추가나 늦어질 때는 AI에게 물어보세요.',
                  style: TextStyle(color: AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            TextButton(onPressed: () => widget.onOpenAssistant?.call(null), child: const Text('AI 도우미')),
          ]),
        ),
      ],
      const SizedBox(height: 8),
      Text(
        widget.isDemo
            ? '시연 데이터 기준이에요. 실시간 교통 정보가 아니에요.'
            : '"역산" 표시가 있는 시각은 실시간 도착 정보 없이 소요시간으로 계산한 값이에요.',
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
  });

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
        sideValue = e.dwell <= 0 ? '불가' : '최대 ${e.dwell}분';
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
                Text(index == 0 ? '최적' : '대안',
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
                    Text('${route.totalMinutes}분',
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
                    Text(
                      '${KstTime.hm(times.depart)} → ${KstTime.hm(times.arrive)}${times.derived ? ' (역산)' : ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(sideLabel, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                  Text(sideValue, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: sideColor)),
                ]),
              ]),
              const SizedBox(height: 10),
              RouteTimeStrip(route: route),
              const SizedBox(height: 4),
              Text(
                [
                  for (final s in route.segments.where((s) => s.durationMinutes > 0 && s.type != RouteSegmentType.waiting))
                    '${_label(s)} ${s.durationMinutes}분',
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
      m('추천 출발', KstTime.hm(times.depart)),
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
