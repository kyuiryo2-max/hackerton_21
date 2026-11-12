import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../config/api_config.dart';
import '../config/app_theme.dart';
import '../data/offline_demo_data.dart';
import '../models/departure_overview.dart';
import '../models/route_candidate.dart';
import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../providers/active_route_controller.dart';
import '../providers/schedule_controller.dart';
import '../providers/todo_controller.dart';
import '../services/approximate_location_service.dart';
import '../services/departure_alert_service.dart';
import '../services/kst_time.dart';
import '../services/server_plan_service.dart';
import '../widgets/open_on_phone.dart';
import '../models/place.dart';
import 'place_search_screen.dart';
import 'schedule_form_screen.dart';

/// 홈: 지도 앱처럼 "내 위치" 지도 + 다음 일정 카드만 간단히.
/// 경로 추천·들를 곳·대안 경로 비교는 모두 길찾기 탭에서 해요.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onOpenRoutes,
    required this.onSelectWaypoint,
    this.onOpenScheduleRoutes,
    this.onOpenTab,
    this.onOpenAssistant,
    this.onChangeMode,
    this.onSearchDestination,
  });

  /// 검색창에서 목적지를 고르면 (일정 없이 경로 검색)
  final ValueChanged<Place>? onSearchDestination;

  /// 이동 탭 열기
  final VoidCallback onOpenRoutes;
  final ValueChanged<Schedule>? onOpenScheduleRoutes;
  final ValueChanged<TodoItem> onSelectWaypoint;
  final ValueChanged<int>? onOpenTab;
  final ValueChanged<String?>? onOpenAssistant;
  final VoidCallback? onChangeMode;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  static const LatLng _seoul = LatLng(37.5665, 126.9780);

  final MapController _map = MapController();
  final ApproximateLocationService _region = ApproximateLocationService();
  final DepartureAlertService _alerts = DepartureAlertService();

  Timer? _ticker;
  DateTime _now = DateTime.now();
  final DateTime _clockAnchor = DateTime.now();

  LatLng? _me;
  double? _accuracy;
  String? _regionName;
  String? _locationError;
  bool _locating = false;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _locate();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _locationError = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('기기의 위치 서비스가 꺼져 있어요');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        throw StateError('위치 권한이 필요해요');
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final here = LatLng(p.latitude, p.longitude);
      setState(() {
        _me = here;
        _accuracy = p.accuracy;
      });
      if (_mapReady) _map.move(here, 16);
      try {
        final name = await _region.regionFor(p.latitude, p.longitude);
        if (mounted) setState(() => _regionName = name);
      } catch (_) {
        // 지역 이름은 없어도 지도는 보여 줄 수 있어요.
      }
    } catch (e) {
      if (mounted) {
        setState(() => _locationError = e is StateError ? e.message : '현재 위치를 찾지 못했어요');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // ---------- 다음 일정 ----------

  DepartureOverview? _overview(Schedule? next) {
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
        );
      }
      final route = active.selected;
      return DepartureOverview(
        source: DepartureSource.selectedRoute,
        title: next?.title ?? '${active.destination} 가기',
        destination: active.destination,
        prepMinutes: next?.preparationMinutes ?? 30,
        departure: active.arrival.subtract(Duration(minutes: route.totalMinutes)),
        arriveBy: active.arrival,
        totalMinutes: route.totalMinutes,
        transitLabel: _firstTransit(route),
      );
    }
    if (ApiConfig.demoMode) {
      return DepartureOverview.fromPlan(
        ServerPlan(OfflineDemoData.plan),
        source: DepartureSource.offlineDemo,
        title: '청량리역 가기 · 시연 일정',
      );
    }
    if (next == null) return null;
    return DepartureOverview(
      source: DepartureSource.scheduleEstimate,
      title: next.title,
      destination: next.location,
      prepMinutes: next.preparationMinutes,
      departure: _alerts.calculateDepartureTime(next.startTime),
      arriveBy: next.startTime,
      destinationPoint: next.destinationLatitude == null || next.destinationLongitude == null
          ? null
          : GeoPoint(next.location, next.destinationLatitude!, next.destinationLongitude!),
    );
  }

  static String? _firstTransit(RouteCandidate route) {
    for (final s in route.segments) {
      if (s.type == RouteSegmentType.bus || s.type == RouteSegmentType.subway) {
        final name = s.lineName?.trim();
        if (name == null || name.isEmpty) return s.type == RouteSegmentType.bus ? '버스' : '지하철';
        return s.type == RouteSegmentType.bus && !name.endsWith('번') ? '$name번 버스' : name;
      }
    }
    return null;
  }

  DateTime _refNow(DepartureOverview? o) {
    final demoNow = o?.demoNow;
    return demoNow == null ? _now : demoNow.add(_now.difference(_clockAnchor));
  }

  Future<void> _addSchedule() async {
    final saved = await Navigator.push<Schedule>(
      context,
      MaterialPageRoute(builder: (_) => const ScheduleFormScreen()),
    );
    if (saved == null || !mounted) return;
    // 저장만 하고 홈에 그대로 있어요. 경로는 원할 때 [경로 보기]로.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved.id == 0
          ? '「${saved.title}」 매주 반복 일정을 저장했어요. 할 일·일정 탭에서 볼 수 있어요.'
          : '「${saved.title}」 일정을 저장했어요.'),
      action: saved.id == 0
          ? null
          : SnackBarAction(label: '경로 보기', onPressed: () => widget.onOpenScheduleRoutes?.call(saved)),
    ));
  }

  Future<void> _searchDestination() async {
    final place = await Navigator.push<Place>(
      context,
      MaterialPageRoute(builder: (_) => const PlaceSearchScreen(title: '어디로 가시나요?')),
    );
    if (place != null && mounted) widget.onSearchDestination?.call(place);
  }

  // ---------- 화면 ----------

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final schedules = ScheduleScope.of(context).schedules;
    final todos = TodoScope.of(context).todos;
    final upcoming = schedules.where((s) => !s.isCompleted && s.startTime.isAfter(_now)).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    final next = upcoming.isEmpty ? null : upcoming.first;
    final todayCount = schedules
        .where((s) => s.startTime.year == _now.year && s.startTime.month == _now.month && s.startTime.day == _now.day)
        .length;
    final openTodos = todos.where((t) => !t.isCompleted).length;

    final demoSpot = GeoPoint.fromJson(OfflineDemoData.context['location']);
    final demoLatLng = demoSpot == null ? null : LatLng(demoSpot.lat, demoSpot.lng);
    final usingDemoSpot = _me == null && ApiConfig.demoMode && demoLatLng != null;
    final center = _me ?? (usingDemoSpot ? demoLatLng : null) ?? _seoul;

    return Scaffold(
      body: AnimatedBuilder(
        animation: activeRouteController,
        builder: (context, _) {
          final o = _overview(next);
          final now = _refNow(o);
          final dest = o?.destinationPoint;
          return Stack(children: [
            // 지도 (내 위치 중심)
            Positioned.fill(
              child: FlutterMap(
                mapController: _map,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: 16,
                  onMapReady: () {
                    _mapReady = true;
                    if (_me != null) _map.move(_me!, 16);
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.syncro.sync_ro_app',
                  ),
                  if (_me != null && _accuracy != null && _accuracy! > 15)
                    CircleLayer(circles: [
                      CircleMarker(
                        point: _me!,
                        radius: _accuracy!,
                        useRadiusInMeter: true,
                        color: AppTheme.primary.withValues(alpha: 0.10),
                        borderColor: AppTheme.primary.withValues(alpha: 0.35),
                        borderStrokeWidth: 1,
                      ),
                    ]),
                  MarkerLayer(markers: [
                    if (dest != null)
                      Marker(
                        point: LatLng(dest.lat, dest.lng),
                        width: 150,
                        height: 58,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            margin: const EdgeInsets.only(bottom: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(color: AppTheme.textStrong, borderRadius: BorderRadius.circular(7)),
                            child: Text('${dest.name} ${o?.arriveBy == null ? '' : KstTime.hm(o!.arriveBy)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                          ),
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              color: AppTheme.textStrong,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                          ),
                        ]),
                      ),
                    if (_me != null || usingDemoSpot)
                      Marker(
                        point: center,
                        width: 40,
                        height: 40,
                        child: Center(
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: usingDemoSpot ? AppTheme.warn : AppTheme.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 4),
                              boxShadow: [
                                BoxShadow(
                                  color: (usingDemoSpot ? AppTheme.warn : AppTheme.primary).withValues(alpha: 0.35),
                                  spreadRadius: 8,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ]),
                ],
              ),
            ),

            // 위: 상단 바 + 위치 칩
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _SearchBar(onTap: _searchDestination),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(child: Align(alignment: Alignment.centerLeft, child: _Glass(
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.near_me_rounded,
                              size: 15, color: _locationError != null && !usingDemoSpot ? AppTheme.danger : AppTheme.primary),
                          const SizedBox(width: 5),
                          Flexible(child: Text(
                            _locating
                                ? '내 위치 찾는 중…'
                                : _me != null
                                    ? (_regionName ?? '내 위치')
                                    : usingDemoSpot
                                        ? '시연 위치 · ${demoSpot?.name ?? ''}'
                                        : (_locationError ?? '위치를 확인하지 못했어요'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                          )),
                        ]),
                      ))),
                      const SizedBox(width: 8),
                      const OpenOnPhoneButton(),
                      _ModePill(isDemo: ApiConfig.demoMode, onTap: widget.onChangeMode),
                    ]),
                  ]),
                ),
              ),
            ),

            // 지도 출처 (카드에 가리지 않게)
            const Positioned(
              left: 14,
              bottom: 300,
              child: _Glass(
                child: Text('© OpenStreetMap contributors', style: TextStyle(fontSize: 10, color: AppTheme.textMuted)),
              ),
            ),

            // 오른쪽: 내 위치로
            Positioned(
              right: 14,
              bottom: 298,
              child: Material(
                color: Colors.white,
                shape: const CircleBorder(side: BorderSide(color: AppTheme.border)),
                elevation: 2,
                child: IconButton(
                  tooltip: '내 위치로',
                  onPressed: () {
                    if (_me != null && _mapReady) {
                      _map.move(_me!, 16);
                    } else {
                      _locate();
                    }
                  },
                  icon: _locating
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.my_location_rounded, color: AppTheme.primary),
                ),
              ),
            ),

            // 아래: 다음 일정 카드
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _NextCard(
                overview: o,
                now: now,
                todayCount: todayCount,
                openTodos: openTodos,
                onOpenRoutes: widget.onOpenRoutes,
                onOpenPlanner: () => widget.onOpenTab?.call(2),
                onAddSchedule: _addSchedule,
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ======================================================================

class _Glass extends StatelessWidget {
  const _Glass({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppTheme.border),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))],
        ),
        child: child,
      );
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: Material(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            elevation: 3,
            shadowColor: const Color(0x33000000),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                child: Row(children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.alt_route_rounded, color: Colors.white, size: 16),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('어디로 가시나요? 목적지 검색',
                        style: TextStyle(color: AppTheme.textMuted, fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  const Icon(Icons.search_rounded, color: AppTheme.textMuted),
                ]),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: AppTheme.primary,
          shape: const CircleBorder(),
          elevation: 3,
          child: IconButton(
            tooltip: '일정 없이 경로 검색',
            onPressed: onTap,
            icon: const Icon(Icons.turn_right_rounded, color: Colors.white),
          ),
        ),
      ]);
}

class _ModePill extends StatelessWidget {
  const _ModePill({required this.isDemo, this.onTap});
  final bool isDemo;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tone = isDemo ? AppTheme.warn : AppTheme.primary;
    return Material(
      color: isDemo ? AppTheme.warnSoft : AppTheme.primarySoft,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(isDemo ? Icons.science_outlined : Icons.person_outline, size: 15, color: tone),
            const SizedBox(width: 4),
            Text(isDemo ? '시연 모드' : '실제 모드', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tone)),
            // 눌러서 바꿀 수 있다는 표시
            Icon(Icons.swap_horiz_rounded, size: 15, color: tone),
          ]),
        ),
      ),
    );
  }
}

class _NextCard extends StatelessWidget {
  const _NextCard({
    required this.overview,
    required this.now,
    required this.todayCount,
    required this.openTodos,
    required this.onOpenRoutes,
    required this.onOpenPlanner,
    required this.onAddSchedule,
  });

  final DepartureOverview? overview;
  final DateTime now;
  final int todayCount;
  final int openTodos;
  final VoidCallback onOpenRoutes;
  final VoidCallback onOpenPlanner;
  final VoidCallback onAddSchedule;

  static String _countdown(Duration d) {
    final total = (d.inSeconds / 60).ceil();
    if (total <= 0) return '0분';
    final h = total ~/ 60, m = total % 60;
    if (h == 0) return '$m분';
    return m == 0 ? '$h시간' : '$h시간 $m분';
  }

  (String, Color) _status(DepartureOverview o) {
    final dep = o.departure;
    if (dep == null) return ('출발 시각 계산 전', AppTheme.textMuted);
    final prep = o.prepStart;
    if (prep != null && now.isBefore(prep)) return ('준비 시작까지 ${_countdown(prep.difference(now))}', AppTheme.primary);
    if (now.isBefore(dep)) return ('출발까지 ${_countdown(dep.difference(now))}', AppTheme.warn);
    final late = now.difference(dep).inMinutes;
    if (late <= 1) return ('지금 출발하세요', AppTheme.warn);
    return ('추천 출발이 $late분 지났어요', AppTheme.danger);
  }

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final decoration = BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: AppTheme.border),
      boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 24, offset: Offset(0, 8))],
    );

    if (o == null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: decoration,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const Text('다가오는 일정이 없어요', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('일정을 추가하면 언제 나가야 하는지 알려 드려요.', style: TextStyle(color: AppTheme.textMuted)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: onAddSchedule,
                icon: const Icon(Icons.add_rounded),
                label: const Text('일정 추가'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: onOpenRoutes, child: const Text('길찾기')),
          ]),
        ]),
      );
    }

    final (status, tone) = _status(o);
    final badge = switch (o.source) {
      DepartureSource.serverDemo || DepartureSource.offlineDemo => '시연',
      DepartureSource.scheduleEstimate => '임시 추정',
      _ => '경로 기준',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: decoration,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Text('다음 일정', style: TextStyle(fontSize: 12, color: AppTheme.textMuted, fontWeight: FontWeight.w600)),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(6)),
            child: Text(badge, style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.w700)),
          ),
          const Spacer(),
          Text(o.arriveBy == null ? '' : '${KstTime.hm(o.arriveBy)} 도착',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 4),
        Text(o.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
        Row(children: [
          const Icon(Icons.place_outlined, size: 15, color: AppTheme.textMuted),
          const SizedBox(width: 3),
          Expanded(
            child: Text(o.destination,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppTheme.textMuted)),
          ),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('추천 출발', style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
              Text(o.departure == null ? '--:--' : KstTime.hm(o.departure),
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
            ]),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(status, style: TextStyle(fontWeight: FontWeight.w800, color: tone)),
                Text(
                  o.isEstimate
                      ? '이동 35분 + 여유 10분 임시 계산'
                      : [
                          if (o.transitLabel != null) o.transitLabel!,
                          if (o.boardAt != null) '${KstTime.hm(o.boardAt)} 탑승 예정',
                        ].join(' · '),
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: onOpenRoutes,
            child: const Text('추천 경로 및 대안 보기 →'),
          ),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: TextButton.icon(
              onPressed: onAddSchedule,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('일정 추가'),
            ),
          ),
          Expanded(
            child: TextButton.icon(
              onPressed: onOpenPlanner,
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: Text(openTodos == 0 ? '할 일 추가' : '할 일 $openTodos개'),
            ),
          ),
        ]),
      ]),
    );
  }
}
