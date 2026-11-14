import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import '../config/map_tiles.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
import '../services/location_access.dart';
import '../services/nearby_todo_service.dart';
import '../services/prep_notification_service.dart';
import '../services/server_plan_service.dart';
import '../widgets/home/stay_planner_card.dart' show hm, stayColor, staySoft;
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
  /// 웹에서 처음 왔을 때: 바로 권한 창을 띄우지 않고 "내 위치 보기"를 누르게 해요
  bool _askLocation = false;
  LocationIssue? _issue;

  /// 실제 모드: 다음 일정 + 할 일로 받아 온 서버 계획 (경유지 판단에 써요)
  ServerPlan? _homePlan;
  int? _homePlanScheduleId;
  String? _homePlanKey;

  /// 평상시: 할 일을 할 수 있는 근처 장소 (최대 5곳)
  final NearbyTodoService _nearby = NearbyTodoService();
  List<NearbySpot> _spots = const [];
  String? _spotsKey;
  bool _spotsLoading = false;

  /// "경로 따라가기"를 누른 일정 (앱을 다시 켜도 유지)
  static const String _followPref = 'sync_ro_following_v1';
  String? _following;
  /// 준비 안내 창을 이미 띄운 일정
  String? _promptedKey;
  /// 휴대폰 알림을 걸어 둔 일정·시각
  String? _notifKey;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startLocation();
    });
    _loadFollowing();
    PrepNotificationService.instance.init().then((_) => PrepNotificationService.instance.askPermissionOnce());
    PrepNotificationService.instance.tapped.addListener(_onNotificationTap);
  }

  Future<void> _loadFollowing() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_followPref);
      if (mounted && saved != null) setState(() => _following = saved);
    } catch (_) {}
  }

  /// 알림을 눌러 들어오면 준비 안내 창을 다시 띄워요.
  void _onNotificationTap() {
    if (mounted) setState(() => _promptedKey = null);
  }

  /// 설치 앱이거나 예전에 허용한 적이 있으면 바로 위치를 찾고,
  /// 웹 첫 방문이면 "내 위치 보기" 버튼으로 안내해요 (브라우저는 누른 뒤에 물어봐야 허용 창을 잘 띄워요).
  Future<void> _startLocation() async {
    if (!kIsWeb || await LocationAccess.wasGranted()) {
      _locate();
    } else if (mounted) {
      setState(() => _askLocation = true);
    }
  }

  void _showLocationHelp() {
    final issue = _issue;
    if (issue == null) return;
    LocationAccess.showHelp(
      context,
      issue,
      onRetry: () => _locate(fromTap: true),
      onWithoutLocation: () {},
      withoutLabel: ApiConfig.demoMode ? '시연 위치로 계속하기' : '위치 없이 계속하기 (출발지는 직접 골라요)',
    );
  }

  void _onLocationChipTap() {
    if (_locating) return;
    if (_me != null) {
      if (_mapReady) _map.move(_me!, 16);
    } else if (_issue != null) {
      _showLocationHelp();
    } else {
      _locate(fromTap: true);
    }
  }

  @override
  void dispose() {
    PrepNotificationService.instance.tapped.removeListener(_onNotificationTap);
    _nearby.dispose();
    _ticker?.cancel();
    _map.dispose();
    super.dispose();
  }

  Future<void> _locate({bool fromTap = false}) async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _locationError = null;
      _issue = null;
      _askLocation = false;
    });
    try {
      final p = await LocationAccess.current();
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
    } on LocationAccessException catch (e) {
      if (!mounted) return;
      setState(() {
        _locationError = e.message;
        _issue = e.issue;
      });
      // 사용자가 직접 눌렀는데 막혔으면 켜는 방법을 바로 보여 줘요
      if (fromTap) _showLocationHelp();
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  // ---------- 다음 일정 ----------

  DepartureOverview? _overview(Schedule? next) {
    var active = activeRouteController.active;
    // 홈은 "다음 일정"을 보여 줘요. 이동 탭에서 다른 일정 경로를 보고 있으면 그 경로는 쓰지 않아요
    // (11/13: 오늘 일정 제목에 내일 일정 경로가 섞여 나오던 문제)
    if (active != null && next != null &&
        ActiveRouteController.tripKey(active.destination, active.arrival) !=
            ActiveRouteController.tripKey(next.location, next.startTime)) {
      active = null;
    }
    if (active != null) {
      var plan = active.plan;
      if (plan != null) {
        // 실제 모드: 이동 탭에서 고른 경로로 보여 줘요 (11/13). 시연 계획은 경로가 하나라 그대로예요.
        final rank = int.tryParse(active.selectedId.replaceFirst('server_', ''));
        if (!ApiConfig.demoMode && active.selectedId.startsWith('server_') && rank != null) {
          plan = plan.forRank(rank);
        }
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
    final homePlan = _homePlan;
    if (homePlan != null && _homePlanScheduleId == next.id) {
      final todos = TodoScope.of(context).todos;
      return DepartureOverview.fromPlan(
        homePlan,
        source: DepartureSource.serverPlan,
        title: next.title,
        destination: next.location,
        fallbackPrepMinutes: next.preparationMinutes,
        fallbackArriveBy: next.startTime,
        fallbackNeedMinutes: (title) {
          for (final t in todos) {
            if (t.title == title && t.estimatedMinutes > 0) return t.estimatedMinutes;
          }
          return 5;
        },
      );
    }
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

  /// 실제 모드에서 다음 일정이 있으면, 열린 할 일을 넣어 서버 계획을 한 번 받아 둬요.
  /// 같은 일정·할 일·위치면 다시 부르지 않아요.
  void _maybeFetchHomePlan(Schedule? next, List<TodoItem> todos) {
    if (ApiConfig.demoMode || next == null || next.id <= 0 || _me == null) return;
    if (activeRouteController.active?.plan != null) return;
    final todoIds = todos.where((t) => !t.isCompleted).map((t) => t.id).toList()..sort();
    final key = '${next.id}|${next.startTime.millisecondsSinceEpoch}|${todoIds.join(',')}|'
        '${_me!.latitude.toStringAsFixed(3)},${_me!.longitude.toStringAsFixed(3)}';
    if (key == _homePlanKey) return;
    _homePlanKey = key;
    final me = _me!;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final service = ServerPlanService();
      try {
        final plan = await service.fetch(
          scheduleId: next.id,
          todoIds: todoIds,
          originLat: me.latitude,
          originLng: me.longitude,
        );
        if (!mounted || _homePlanKey != key) return;
        setState(() {
          _homePlan = plan;
          _homePlanScheduleId = next.id;
        });
      } catch (_) {
        // 서버가 없거나 실패하면 홈은 임시 추정으로 보여 줘요.
      } finally {
        service.dispose();
      }
    });
  }

  // ---------- 평상시 / 준비 / 따라가기 ----------

  /// 일정마다 하나인 키. 시연은 'demo'.
  static String? _planKey(Schedule? next, DepartureOverview? o) {
    if (o == null) return null;
    if (next != null && !o.isDemo) return 's${next.id}@${next.startTime.millisecondsSinceEpoch}';
    return o.isDemo ? 'demo' : null;
  }

  /// 경유지가 있으면 들러서 나가는 시각, 없으면 추천 출발
  static DateTime? _departOf(DepartureOverview o) => homeStop(o)?.eval.depart ?? o.departure;
  static DateTime? _prepAt(DepartureOverview o) => _departOf(o)?.subtract(Duration(minutes: o.prepMinutes));

  _HomePhase _phaseOf(String? key, DepartureOverview? o, DateTime now) {
    if (o == null || key == null) return _HomePhase.free;
    if (_following == key || activeRouteController.active != null) return _HomePhase.follow;
    final prep = _prepAt(o);
    if (prep != null && !now.isBefore(prep)) return _HomePhase.prep;
    return _HomePhase.free;
  }

  Future<void> _follow(String? key, Schedule? next) async {
    if (key == null) return;
    setState(() => _following = key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_followPref, key);
    } catch (_) {}
    if (!mounted) return;
    if (next != null && !ApiConfig.demoMode) {
      widget.onOpenScheduleRoutes?.call(next);
    } else {
      widget.onOpenRoutes();
    }
  }

  Future<void> _stopFollowing() async {
    setState(() => _following = null);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_followPref);
    } catch (_) {}
  }

  /// 준비 시각이 되면 앱 안에서도 한 번 물어봐요: "경로 따라가기"
  void _maybePrompt(_HomePhase phase, String? key, DepartureOverview? o, Schedule? next) {
    if (phase != _HomePhase.prep || key == null || o == null || _promptedKey == key) return;
    _promptedKey = key;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final stop = homeStop(o);
      final dep = _departOf(o);
      final arrive = o.arriveAt ?? o.arriveBy;
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.alarm_rounded, color: AppTheme.primary),
          title: const Text('일정 준비할 시간이에요'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(o.title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text('${hm(dep)} 출발 → ${hm(arrive)} 도착'),
            if (stop != null)
              Text('가는 길에 ${stop.task.title} · ${stop.eval.candidate.name} '
                  '${stop.eval.ample ? '(시간 충분)' : stop.eval.dwell > 0 ? '최대 ${stop.eval.dwell}분' : '(시간 부족)'}',
                  style: const TextStyle(color: AppTheme.textMuted)),
            const SizedBox(height: 8),
            const Text('이 경로를 따라가면 지금부터 추천 경로를 보여 드릴게요.',
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('나중에')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('경로 따라가기')),
          ],
        ),
      );
      if (go == true && mounted) _follow(key, next);
    });
  }

  /// 다음 일정 준비 시각에 휴대폰 알림을 걸어 둬요 (시각이 바뀌면 다시 걸어요).
  void _maybeScheduleNotification(Schedule? next, DepartureOverview? o) {
    if (next == null || o == null || o.isDemo) return;
    final prep = _prepAt(o), dep = _departOf(o);
    if (prep == null || dep == null) return;
    final key = '${next.id}|${prep.millisecondsSinceEpoch ~/ 60000}';
    if (key == _notifKey) return;
    _notifKey = key;
    PrepNotificationService.instance.schedulePrep(scheduleId: next.id, title: next.title, at: prep, departure: dep);
  }

  /// 내 위치(또는 시연 위치) 근처에서 할 일을 할 수 있는 곳을 찾아요. 위치가 100m쯤 바뀌거나 할 일이 바뀌면 다시 찾아요.
  void _maybeFindSpots(List<TodoItem> todos, LatLng? at) {
    if (at == null) return;
    final open = todos.where((t) => !t.isCompleted && NearbyTodoService.keywordsOf(t).isNotEmpty).toList();
    final key = '${open.map((t) => '${t.id}:${NearbyTodoService.keywordsOf(t).join('/')}:${t.important}').join(',')}|'
        '${at.latitude.toStringAsFixed(3)},${at.longitude.toStringAsFixed(3)}';
    if (key == _spotsKey) return;
    _spotsKey = key;
    if (open.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _spots = const []);
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() => _spotsLoading = true);
      final found = await _nearby.find(open, at.latitude, at.longitude, region: _regionName);
      if (!mounted || _spotsKey != key) return;
      setState(() {
        _spots = found;
        _spotsLoading = false;
      });
    });
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
    _maybeFetchHomePlan(next, todos);

    final demoSpot = GeoPoint.fromJson(OfflineDemoData.context['location']);
    final demoLatLng = demoSpot == null ? null : LatLng(demoSpot.lat, demoSpot.lng);
    final usingDemoSpot = _me == null && ApiConfig.demoMode && demoLatLng != null;
    final center = _me ?? (usingDemoSpot ? demoLatLng : null) ?? _seoul;
    final hasPlaceTodos = todos.any((t) => !t.isCompleted && NearbyTodoService.keywordsOf(t).isNotEmpty);
    _maybeFindSpots(todos, _me ?? (usingDemoSpot ? demoLatLng : null));

    return Scaffold(
      body: AnimatedBuilder(
        animation: activeRouteController,
        builder: (context, _) {
          final o = _overview(next);
          final now = _refNow(o);
          final dest = o?.destinationPoint;
          final planKey = _planKey(next, o);
          final phase = _phaseOf(planKey, o, now);
          _maybePrompt(phase, planKey, o, next);
          _maybeScheduleNotification(next, o);
          // 평상시엔 근처 할 일 장소, 준비·따라가기 땐 경유지 핀
          final stop = phase == _HomePhase.free ? null : homeStop(o);
          final stopPoint = stop?.eval.candidate.point;
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
                  MapTiles.layer(),
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
                    if (phase == _HomePhase.free)
                      for (var i = 0; i < _spots.length; i++)
                        Marker(
                          point: LatLng(_spots[i].place.latitude, _spots[i].place.longitude),
                          width: 130,
                          height: 50,
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Container(
                              margin: const EdgeInsets.only(bottom: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(color: AppTheme.border),
                              ),
                              child: Text(_spots[i].todo.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                            ),
                            Container(
                              width: 22,
                              height: 22,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppTheme.primary,
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                              child: Text('${i + 1}',
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                            ),
                          ]),
                        ),
                    if (stop != null && stopPoint != null)
                      Marker(
                        point: LatLng(stopPoint.lat, stopPoint.lng),
                        width: 160,
                        height: 56,
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            margin: const EdgeInsets.only(bottom: 3),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: stayColor(stop.eval.status),
                              borderRadius: BorderRadius.circular(7),
                            ),
                            child: Text(
                              stop.eval.dwell > 0
                                  ? '${stop.eval.candidate.name} ${stop.eval.stayLabel}'
                                  : '${stop.eval.candidate.name} 시간 부족',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                            ),
                          ),
                          Container(
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: stayColor(stop.eval.status),
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 3),
                            ),
                          ),
                        ]),
                      ),
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
                      Expanded(child: Align(alignment: Alignment.centerLeft, child: GestureDetector(
                        onTap: _onLocationChipTap,
                        child: _Glass(
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.near_me_rounded,
                              size: 15, color: _issue != null ? AppTheme.warn : AppTheme.primary),
                          const SizedBox(width: 5),
                          Flexible(child: Text(
                            _locating
                                ? '내 위치 찾는 중…'
                                : _me != null
                                    ? (_regionName ?? '내 위치')
                                    : _askLocation
                                        ? '내 위치 보기 · 눌러서 켜기'
                                        : _issue != null
                                            ? '위치가 꺼져 있어요 · 켜는 방법'
                                            : usingDemoSpot
                                                ? '시연 위치 · ${demoSpot?.name ?? ''}'
                                                : (_locationError ?? '위치를 확인하지 못했어요'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                          )),
                          if (_askLocation || _issue != null) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right_rounded, size: 16, color: AppTheme.primary),
                          ],
                        ]),
                      )))),
                      const SizedBox(width: 8),
                      const OpenOnPhoneButton(),
                      _ModePill(isDemo: ApiConfig.demoMode, onTap: widget.onChangeMode),
                    ]),
                  ]),
                ),
              ),
            ),

            // 아래: (지도 출처 · 내 위치 버튼) + 카드. 카드 높이가 바뀌어도 버튼이 같이 움직여요.
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  _Glass(
                    child: Text(MapTiles.creditText,
                        style: const TextStyle(fontSize: 10, color: AppTheme.textMuted)),
                  ),
                  const Spacer(),
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(side: BorderSide(color: AppTheme.border)),
                    elevation: 2,
                    child: IconButton(
                      tooltip: '내 위치로',
                      onPressed: () {
                        if (_me != null && _mapReady) {
                          _map.move(_me!, 16);
                        } else if (_issue == LocationIssue.denied || _issue == LocationIssue.serviceOff) {
                          _showLocationHelp();
                        } else {
                          _locate(fromTap: true);
                        }
                      },
                      icon: _locating
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.my_location_rounded, color: AppTheme.primary),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                if (phase == _HomePhase.free)
                  _NearbyCard(
                    spots: _spots,
                    loading: _spotsLoading,
                    hasPlaceTodos: hasPlaceTodos,
                    located: _me != null || usingDemoSpot,
                    overview: o,
                    prepAt: o == null ? null : _prepAt(o),
                    onFocus: (spot) {
                      if (_mapReady) _map.move(LatLng(spot.place.latitude, spot.place.longitude), 17);
                    },
                    onGo: (spot) => widget.onSearchDestination?.call(spot.place),
                    onPreview: widget.onOpenRoutes,
                    onOpenPlanner: () => widget.onOpenTab?.call(2),
                    onAddSchedule: _addSchedule,
                  )
                else
                  _NextCard(
                    overview: o,
                    now: now,
                    todayCount: todayCount,
                    openTodos: openTodos,
                    preparing: phase == _HomePhase.prep,
                    following: planKey != null && _following == planKey,
                    onFollow: () => _follow(planKey, next),
                    onStopFollow: _stopFollowing,
                    onOpenRoutes: widget.onOpenRoutes,
                    onOpenPlanner: () => widget.onOpenTab?.call(2),
                    onAddSchedule: _addSchedule,
                  ),
              ]),
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

/// 홈에서 보여 줄 경유지 하나.
/// 실제 모드: 이동 탭에서 "이번 이동에 적용한" 할 일이 있을 때만, 고른 경유지로 보여 줘요 (11/13).
/// 시연 모드: 무대 장면이라 예전처럼 첫 할 일의 가장 오래 머물 수 있는 곳을 바로 보여 줘요.
({StayTask task, StayEval eval})? homeStop(DepartureOverview? o) {
  if (o == null || !o.canPlanStay || o.tasks.isEmpty) return null;
  var task = o.tasks.first;
  String? candidateId;
  if (!o.isDemo) {
    final id = activeRouteController.appliedTaskId;
    // 이 일정(목적지 + 도착 시각)에 적용한 할 일일 때만
    if (id == null || !activeRouteController.appliedFor(ActiveRouteController.tripKey(o.destination, o.arriveBy))) {
      return null;
    }
    // 여러 곳을 고르면 '1+3' (11/14)
    final match = o.taskFor(id);
    if (match == null) return null;
    task = match;
    candidateId = activeRouteController.appliedCandidateId;
  }
  final ranked = o.rank(task, delayMinutes: 0, need: task.needMinutes);
  if (ranked.isEmpty) return null;
  final eval = ranked.firstWhere((e) => e.candidate.id == candidateId, orElse: () => ranked.first);
  return (task: task, eval: eval);
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
    this.preparing = false,
    this.following = false,
    this.onFollow,
    this.onStopFollow,
  });

  /// 준비 시각이 됐어요: 큰 버튼이 "경로 따라가기"
  final bool preparing;
  /// 사용자가 이 일정의 경로를 따라가는 중
  final bool following;
  final VoidCallback? onFollow;
  final VoidCallback? onStopFollow;
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

  /// "버스 12분 뒤 도착 · 다음 20분 뒤" / "정류장 대기 약 5분"
  String? _vehicleLine(DepartureOverview o) {
    if (o.isEstimate) return null;
    final soon = o.nextVehiclesAt(now);
    if (soon.isNotEmpty) {
      final first = soon.first == 0 ? '곧 도착' : '${soon.first}분 뒤 도착';
      return soon.length > 1 ? '다음 차 $first · 그다음 ${soon[1]}분 뒤' : '다음 차 $first';
    }
    final w = o.waitMinutes;
    return w == null || w <= 0 ? null : '정류장 대기 약 $w분 (실시간은 출발 30분 전부터)';
  }

  (String, Color) _status(DepartureOverview o, [DateTime? stopDepart]) {
    final dep = stopDepart ?? o.departure;
    if (dep == null) return ('출발 시각 계산 전', AppTheme.textMuted);
    final prep = dep.subtract(Duration(minutes: o.prepMinutes));
    if (now.isBefore(prep)) return ('준비 시작까지 ${_countdown(prep.difference(now))}', AppTheme.primary);
    if (now.isBefore(dep)) return ('출발까지 ${_countdown(dep.difference(now))}', AppTheme.warn);
    final late = now.difference(dep).inMinutes;
    if (late <= 1) return ('지금 출발하세요', AppTheme.warn);
    return ('추천 출발이 $late분 지났어요', AppTheme.danger);
  }

  /// 추천 출발 칸 안에 붙는 경유 정보: [경유지 최대 N분] [도착 HH:MM · 총 N분] + 한 줄 판단
  List<Widget> _stopRows(DepartureOverview o, StayTask task, StayEval e) {
    final arrive = o.arriveAt ?? o.arriveBy;
    final total = arrive?.difference(e.depart).inMinutes;
    final c = stayColor(e.status);
    final String verdict;
    if (e.ample) {
      verdict = '경유지를 들르기에 충분해요! ${task.title} ${e.dwell}분 잡아 뒀어요';
    } else if (e.status == StayStatus.bad) {
      final latest = e.latestDepart;
      verdict = latest != null && latest.isAfter(now)
          ? '${task.title} ${e.need}분엔 ${e.shortBy}분 부족 · ${hm(latest)}까지 나가면 돼요'
          : '${task.title} ${e.need}분엔 ${e.shortBy}분 부족 · 다른 곳을 골라 보세요';
    } else if (e.status == StayStatus.tight) {
      verdict = '${task.title} 빠듯해요 · ${hm(e.leavePlace)}엔 나와야 해요';
    } else {
      verdict = '${task.title} 들렀다 가도 ${arrive == null ? '늦지 않아요' : '${hm(arrive)} 도착해요'}';
    }
    Widget cell(String label, String value, {Color? tint, String? sub}) => Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: tint == null ? Colors.white : staySoft(e.status),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: tint ?? AppTheme.textMuted, fontWeight: FontWeight.w600)),
              Text.rich(
                TextSpan(children: [
                  TextSpan(text: value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: tint)),
                  if (sub != null)
                    TextSpan(text: ' $sub', style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
        );
    return [
      const SizedBox(height: 8),
      Row(children: [
        cell('${e.candidate.name}에서', e.dwell > 0 ? e.stayLabel : '시간 부족',
            tint: c, sub: e.ample ? '추천 ${e.dwell}분' : '필요 ${e.need}분'),
        const SizedBox(width: 6),
        cell('최종 도착', hm(arrive), sub: total == null || total <= 0 ? null : '총 $total분'),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        Icon(e.status == StayStatus.bad ? Icons.error_outline_rounded : Icons.check_circle_rounded, size: 14, color: c),
        const SizedBox(width: 4),
        Expanded(
          child: Text(verdict,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c, fontWeight: FontWeight.w700)),
        ),
      ]),
    ];
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

    final stop = homeStop(o);
    final (status, tone) = _status(o, stop?.eval.depart);
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
          if (preparing || following) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: preparing ? AppTheme.warnSoft : AppTheme.okSoft,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(preparing ? '준비할 시간' : '안내 중',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700, color: preparing ? AppTheme.warn : AppTheme.ok)),
            ),
          ],
          const Spacer(),
          if (following && onStopFollow != null)
            GestureDetector(
              onTap: onStopFollow,
              child: const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Text('안내 끄기', style: TextStyle(fontSize: 12, color: AppTheme.textMuted)),
              ),
            ),
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(stop == null ? '추천 출발' : '들러서 출발', style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
              Text(stop != null ? hm(stop.eval.depart) : (o.departure == null ? '--:--' : KstTime.hm(o.departure)),
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
                // 다음 차 대기 (11/14): 실시간이 있으면 "12분 뒤 · 다음 20분", 없으면 서버 대기 시간
                if (_vehicleLine(o) != null)
                  Text(
                    _vehicleLine(o)!,
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppTheme.primary),
                  ),
              ]),
            ),
          ]),
          if (stop != null) ..._stopRows(o, stop.task, stop.eval),
          ]),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: preparing && onFollow != null ? onFollow : onOpenRoutes,
            child: Text(preparing ? '이 경로 따라가기 →' : '추천 경로 및 대안 보기 →'),
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

enum _HomePhase {
  /// 평상시: 근처에서 할 일을 할 수 있는 곳
  free,
  /// 준비 시각이 됐어요: 경로를 따라갈지 물어봐요
  prep,
  /// 경로를 따라가는 중: 경유·출발·도착 카드
  follow,
}

/// 평상시 홈 카드: 할 일을 할 수 있는 근처 장소 (최대 5곳) + 다음 일정 한 줄
class _NearbyCard extends StatelessWidget {
  const _NearbyCard({
    required this.spots,
    required this.loading,
    required this.hasPlaceTodos,
    required this.located,
    required this.overview,
    required this.prepAt,
    required this.onFocus,
    required this.onGo,
    required this.onPreview,
    required this.onOpenPlanner,
    required this.onAddSchedule,
  });

  final List<NearbySpot> spots;
  final bool loading;
  final bool hasPlaceTodos;
  final bool located;
  final DepartureOverview? overview;
  final DateTime? prepAt;
  final ValueChanged<NearbySpot> onFocus;
  final ValueChanged<NearbySpot> onGo;
  final VoidCallback onPreview;
  final VoidCallback onOpenPlanner;
  final VoidCallback onAddSchedule;

  @override
  Widget build(BuildContext context) {
    final o = overview;
    final String? empty = !located
        ? '위치를 켜면 할 일을 할 수 있는 근처 장소를 알려 드려요.'
        : !hasPlaceTodos
            ? '할 일에 장소 종류(편의점, 약국…)가 붙으면 근처 장소를 알려 드려요.'
            : spots.isEmpty && !loading
                ? '근처 ${NearbyTodoService.maxMeters ~/ 1000}km 안에서 할 일 장소를 찾지 못했어요.'
                : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.border),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 24, offset: Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Text('지금 근처에서 할 수 있는 일',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
          const Spacer(),
          if (loading) const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        const SizedBox(height: 6),
        if (empty != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(empty, style: const TextStyle(color: AppTheme.textMuted)),
          )
        else
          for (var i = 0; i < spots.length; i++) _row(i, spots[i]),
        if (o != null) ...[
          const Divider(height: 14),
          Row(children: [
            const Icon(Icons.event_rounded, size: 16, color: AppTheme.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: o.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                  TextSpan(
                    text: [
                      if (o.arriveBy != null) ' ${hm(o.arriveBy)}',
                      if (prepAt != null) ' · ${hm(prepAt)}부터 준비',
                    ].join(),
                    style: const TextStyle(color: AppTheme.textMuted),
                  ),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            TextButton(onPressed: onPreview, child: const Text('경로 미리 보기')),
          ]),
        ],
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
              label: const Text('할 일 보기'),
            ),
          ),
        ]),
      ]),
    );
  }

  Widget _row(int index, NearbySpot spot) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => onFocus(spot),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
            child: Text('${index + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(spot.todo.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                if (spot.todo.important) ...[
                  const SizedBox(width: 4),
                  const Text('꼭', style: TextStyle(fontSize: 11, color: AppTheme.danger, fontWeight: FontWeight.w800)),
                ],
              ]),
              Text('${spot.place.name} · 도보 ${spot.walkMinutes}분 (${spot.distanceLabel})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            ]),
          ),
          IconButton(
            tooltip: '여기로 길찾기',
            visualDensity: VisualDensity.compact,
            onPressed: () => onGo(spot),
            icon: const Icon(Icons.directions_rounded, color: AppTheme.primary),
          ),
        ]),
      ),
    );
  }
}
