import '../config/api_config.dart';
import 'package:flutter/material.dart';

import '../models/place.dart';
import '../models/route_candidate.dart';
import '../models/route_request.dart';
import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../providers/schedule_controller.dart';
import '../providers/todo_controller.dart';
import '../services/route_api_service.dart';
import '../services/server_plan_service.dart';
import '../services/server_route_adapter.dart';
import '../services/place_search_service.dart';
import '../services/location_access.dart';
import 'place_search_screen.dart';
import '../data/offline_demo_data.dart';
import '../widgets/move_route_planner.dart';
import 'package:latlong2/latlong.dart';
import '../providers/active_route_controller.dart';

class NavigationScreen extends StatefulWidget {
  final ValueNotifier<TodoItem?>? selectedWaypoint;
  final ValueNotifier<Schedule?>? requestedSchedule;
  final String? initialDestination;
  final DateTime? initialArrivalTime;
  /// 이동 중 AI 도우미 열기
  final ValueChanged<String?>? onOpenAssistant;
  /// 할 일·일정 탭 열기
  final VoidCallback? onOpenPlanner;
  /// 홈 검색창에서 고른 목적지 (일정 없이 경로 검색)
  final ValueNotifier<Place?>? requestedDestination;

  const NavigationScreen({super.key, this.selectedWaypoint, this.requestedSchedule, this.initialDestination,
    this.initialArrivalTime, this.onOpenAssistant, this.onOpenPlanner, this.requestedDestination});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> with AutomaticKeepAliveClientMixin {
  final _originController = TextEditingController();
  final _manualOriginController = TextEditingController();
  final _manualDestinationController = TextEditingController();
  final _routeApi = RouteApiService();
  final _placeSearch = PlaceSearchService();
  Place? _scheduleDestination;
  String? _destinationLookupMessage;
  bool _resolvingDestination = false;
  String? _scheduleKey;
  int _destinationLookupSerial = 0;
  Place? _origin;
  Place? _manualOrigin;
  Place? _manualDestination;
  DateTime? _manualArrival;
  String? _scheduleError;
  String? _manualError;
  bool _loadingSchedule = false;
  bool _loadingManual = false;
  int _scheduleRequestSerial = 0;
  int _manualRequestSerial = 0;
  bool _manualExpanded = false;
  bool _locating = false;
  String? _locationError;
  bool _didApplyInitial = false;
  bool _manualIsActive = false;
  bool _autoLocating = false;
  Schedule? _explicitSchedule;
  late int _lastPlanRefreshRevision;

  void _handleRequestedSchedule() {
    final requested = widget.requestedSchedule;
    final schedule = requested?.value;
    if (schedule == null) return;
    setState(() {
      _explicitSchedule = schedule;
      _manualIsActive = false;
      _manualExpanded = false;
      _scheduleKey = null; // Re-run destination/location lookup on build.
    });
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _manualDestinationController.text = widget.initialDestination ?? '';
    _manualArrival = widget.initialArrivalTime;
    _lastPlanRefreshRevision = activeRouteController.revision;
    activeRouteController.addListener(_handlePlanRefresh);
    widget.requestedSchedule?.addListener(_handleRequestedSchedule);
    widget.requestedDestination?.addListener(_handleRequestedDestination);
  }

  /// 홈 검색창에서 목적지를 고르면: 현재 위치 → 그 목적지, 지금 출발 기준으로 바로 검색해요.
  Future<void> _handleRequestedDestination() async {
    final place = widget.requestedDestination?.value;
    if (place == null || !mounted) return;
    widget.requestedDestination!.value = null;
    setState(() {
      _manualDestination = place;
      _manualDestinationController.text = place.name;
      _manualArrival = DateTime.now().add(const Duration(hours: 1));
      _manualExpanded = true;
      _manualError = null;
    });
    if (_origin == null || _origin!.id != 'device_current_location') {
      await _useCurrentLocation();
    }
    if (!mounted) return;
    final here = _origin;
    if (here == null) {
      setState(() => _manualError = _locationError ?? '현재 위치를 확인하지 못해 출발지를 직접 골라 주세요.');
      return;
    }
    setState(() {
      _manualOrigin = here;
      _manualOriginController.text = here.name;
    });
    await _loadManualRoutes();
  }

  // Plan refresh notifications must be observed even when the Navigation
  // screen is kept alive offstage (e.g. the user edits a todo on another tab).
  // The inner AnimatedBuilder alone does not rebuild this State's build().
  void _handlePlanRefresh() {
    final revision = activeRouteController.revision;
    if (revision == _lastPlanRefreshRevision) return;
    _lastPlanRefreshRevision = revision;
    // Invalidate any in-flight calculation started before the edit.
    _scheduleRequestSerial++;
    _manualRequestSerial++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Manual searches have no server schedule id, so do not fabricate a
      // stopover plan; ask the user to run the search again.
      if (_manualIsActive) {
        setState(() {
          _manualIsActive = false;
          _manualExpanded = true;
          _manualError = '할 일이 변경되었습니다. 실제 경유 할 일을 반영하려면 일정을 선택해 다시 추천받아 주세요.';
        });
        return;
      }
      final schedule = _explicitSchedule ??
          _nextSchedule(ScheduleScope.of(context).schedules);
      if (schedule == null) return;
      if (_origin != null && _scheduleDestination != null) {
        _loadScheduleRoutes(schedule);
      } else if (_origin == null && schedule.originMode != 'place' && !_autoLocating) {
        _autoLocating = true;
        _useCurrentLocation().whenComplete(() { _autoLocating = false; });
      } else if (_scheduleDestination == null) {
        _resolveScheduleDestination(schedule);
      }
    });
  }

  Schedule? _nextSchedule(List<Schedule> schedules) {
    final now = DateTime.now();
    final upcoming = schedules.where((s) => !s.isCompleted && s.startTime.isAfter(now)).toList()
      ..sort((a, b) => a.startTime.compareTo(b.startTime));
    return upcoming.isEmpty ? null : upcoming.first;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didApplyInitial && widget.initialDestination != null) {
      _didApplyInitial = true;
      _manualExpanded = true;
    }
  }

  Future<Place?> _pickPlace(String title) => Navigator.push<Place>(
    context, MaterialPageRoute(builder: (_) => PlaceSearchScreen(title: title)),
  );

  Future<void> _useCurrentLocation() async {
    if (_locating) return;
    setState(() { _locating = true; _locationError = null; });
    try {
      // 웹(아이폰 Safari 등)에서도 허용 창이 뜨도록 바로 요청해요 (location_access.dart)
      final position = await LocationAccess.current();
      if (!mounted) return;
      final place = Place(
        id: 'device_current_location', name: '현재 위치', address: '기기 위치',
        latitude: position.latitude, longitude: position.longitude,
      );
      setState(() {
        _origin = place;
        _originController.text = place.name;
      });
      final schedule = _explicitSchedule ?? _nextSchedule(ScheduleScope.of(context).schedules);
      if (schedule != null && _scheduleDestination != null && !_manualIsActive) {
        await _loadScheduleRoutes(schedule);
      }
    } on LocationAccessException catch (e) {
      if (!mounted) return;
      setState(() => _locationError = '${e.message}. 출발지를 직접 골라도 돼요.');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message),
        action: SnackBarAction(
          label: '켜는 방법',
          onPressed: () => LocationAccess.showHelp(context, e.issue,
              onRetry: _useCurrentLocation,
              onWithoutLocation: () => setState(() => _manualExpanded = true),
              withoutLabel: '출발지를 직접 고르기'),
        ),
      ));
    } catch (e) {
      if (mounted) setState(() => _locationError = '현재 위치 확인 실패: $e');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _resolveScheduleDestination(Schedule schedule) async {
    final serial = ++_destinationLookupSerial;
    if (schedule.destinationLatitude != null &&
        schedule.destinationLongitude != null) {
      setState(() {
        _scheduleDestination = Place(
          id: schedule.destinationPlaceId ?? '',
          name: schedule.location,
          address: schedule.destinationAddress ?? '',
          latitude: schedule.destinationLatitude!,
          longitude: schedule.destinationLongitude!,
        );
        _destinationLookupMessage = null;
        _resolvingDestination = false;
      });
      if (_origin != null && !_manualIsActive) await _loadScheduleRoutes(schedule);
      return;
    }
    final query = schedule.location.trim();
    if (query.isEmpty) {
      if (mounted) setState(() => _destinationLookupMessage = '일정에 목적지가 등록되어 있지 않습니다.');
      return;
    }
    setState(() { _resolvingDestination = true; _destinationLookupMessage = null; });
    try {
      final places = await _placeSearch.searchPlaces(query);
      if (!mounted || serial != _destinationLookupSerial) return;
      // Do not silently choose a different location when search is ambiguous.
      final exact = places.where((p) => p.name.trim().toLowerCase() == query.toLowerCase()).toList();
      final chosen = exact.length == 1 ? exact.first : (places.length == 1 ? places.first : null);
      setState(() {
        _scheduleDestination = chosen;
        _destinationLookupMessage = chosen == null
            ? (places.isEmpty ? '목적지를 찾지 못했습니다. 장소 검색 데이터 또는 API 연결을 확인해 주세요.' : '목적지 검색 결과가 여러 개입니다. 일정의 장소 이름을 더 구체적으로 입력해 주세요.')
            : null;
      });
      if (chosen != null && _origin != null && !_manualIsActive) await _loadScheduleRoutes(schedule);
    } catch (e) {
      if (mounted && serial == _destinationLookupSerial) {
        setState(() => _destinationLookupMessage = '목적지 검색 실패: $e');
      }
    } finally {
      if (mounted && serial == _destinationLookupSerial) setState(() => _resolvingDestination = false);
    }
  }

  Future<void> _loadScheduleRoutes(Schedule schedule) async {
    if (_origin == null || _scheduleDestination == null) return;
    final serial = ++_scheduleRequestSerial;
    activeRouteController.clearSearch();
    setState(() { _loadingSchedule = true; _scheduleError = null; });
    try {
      if (!ApiConfig.demoMode) {
        final service = ServerPlanService();
        try {
          // The explicit list is important: [] must mean no current tasks,
          // not "reuse a cached server/demo set".
          final activeTodoIds = TodoScope.of(context).todos
              .where((todo) => !todo.isCompleted)
              .map((todo) => todo.id).toList();
          final plan = await service.fetch(
            scheduleId: schedule.id,
            todoIds: activeTodoIds,
            originLat: _origin!.latitude,
            originLng: _origin!.longitude,
          );
          if (!mounted || serial != _scheduleRequestSerial) return;
          final routes = [
            for (var i = 0; i < plan.routes.length; i++)
              ServerRouteAdapter.fromPlan(plan.routes[i], i),
          ];
          if (routes.isEmpty) throw StateError('서버에서 추천 가능한 경로가 없습니다.');
          activeRouteController.setSearch(ActiveRouteSelection(
            routes: routes, selectedId: routes.first.id,
            origin: _origin!.name, destination: schedule.location,
            arrival: schedule.startTime, plan: plan,
          ));
        } finally {
          service.dispose();
        }
      } else {
        final result = await _routeApi.searchWithDetails(RouteRequest(
          origin: _origin!.name, destination: schedule.location,
          desiredArrivalTime: schedule.startTime, originPlace: _origin, destinationPlace: _scheduleDestination,
        ));
        if (!mounted || serial != _scheduleRequestSerial) return;
        final routes = result.routes;
        if (routes.isNotEmpty) {
          activeRouteController.setSearch(ActiveRouteSelection(
            routes: routes, selectedId: routes.first.id,
            origin: _origin!.name, destination: schedule.location, arrival: schedule.startTime,
            plan: result.plan, demoContext: result.demoContext));
        }
      }
    } catch (e) {
      if (mounted && serial == _scheduleRequestSerial) {
        activeRouteController.clearSearch();
        setState(() => _scheduleError = '$e');
      }
    } finally {
      if (mounted && serial == _scheduleRequestSerial) setState(() => _loadingSchedule = false);
    }
  }

  Future<void> _pickManualPlace({required bool origin}) async {
    final place = await _pickPlace(origin ? '출발지 검색' : '목적지 검색');
    if (!mounted || place == null) return;
    setState(() {
      if (origin) { _manualOrigin = place; _manualOriginController.text = place.name; }
      else { _manualDestination = place; _manualDestinationController.text = place.name; }
    });
  }

  Future<void> _pickManualArrival() async {
    final now = DateTime.now();
    final initial = _manualArrival?.isAfter(now) == true ? _manualArrival! : now.add(const Duration(hours: 1));
    final date = await showDatePicker(context: context, initialDate: initial, firstDate: DateTime(now.year, now.month, now.day), lastDate: DateTime(now.year + 5));
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null || !mounted) return;
    setState(() => _manualArrival = DateTime(date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _loadManualRoutes() async {
    if (_manualOriginController.text.trim().isEmpty || _manualDestinationController.text.trim().isEmpty || _manualArrival == null || !_manualArrival!.isAfter(DateTime.now())) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('출발지, 목적지와 미래의 도착시간을 입력해 주세요.')));
      return;
    }
    final serial = ++_manualRequestSerial;
    setState(() { _loadingManual = true; _manualError = null; });
    try {
      final result = await _routeApi.searchWithDetails(RouteRequest(
        origin: _manualOriginController.text.trim(), destination: _manualDestinationController.text.trim(),
        desiredArrivalTime: _manualArrival!, originPlace: _manualOrigin, destinationPlace: _manualDestination,
      ));
      if (!mounted || serial != _manualRequestSerial) return;
      final routes = result.routes;
      if (routes.isNotEmpty) {
        _manualIsActive = true;
        activeRouteController.setSearch(ActiveRouteSelection(
          routes: routes, selectedId: routes.first.id,
          origin: _manualOriginController.text.trim(),
          destination: _manualDestinationController.text.trim(), arrival: _manualArrival!,
          plan: result.plan, demoContext: result.demoContext));
      }
    } catch (e) {
      if (mounted && serial == _manualRequestSerial) setState(() => _manualError = '$e');
    } finally {
      if (mounted && serial == _manualRequestSerial) setState(() => _loadingManual = false);
    }
  }

  Widget _routePanel({required List<RouteCandidate> routes, required String? selectedId,
    required ValueChanged<String> onSelect, required bool loading, required String? error,
    required String originName, required String destinationName, DateTime? arrival,
    Place? origin, Place? destination, String? title,
    ActiveRouteSelection? selection}) {
    final plan = selection?.plan;
    final planNow = plan == null ? null : DateTime.tryParse('${plan.data['now'] ?? ''}');
    final todos = TodoScope.of(context).todos;
    return MoveRoutePlanner(
      routes: routes,
      selectedId: selectedId,
      onSelect: onSelect,
      plan: plan,
      title: title ?? '$destinationName 가기',
      badge: _manualIsActive ? '직접 검색' : (ApiConfig.demoMode ? '시연' : '다음 일정'),
      originName: originName,
      destinationName: destinationName,
      arriveBy: arrival,
      now: planNow ?? DateTime.now(),
      isDemo: ApiConfig.demoMode,
      origin: origin == null ? null : LatLng(origin.latitude, origin.longitude),
      destination: destination == null ? null : LatLng(destination.latitude, destination.longitude),
      onManageSchedule: widget.onOpenPlanner,
      onOpenAssistant: widget.onOpenAssistant,
      fallbackNeed: (t) {
        for (final todo in todos) {
          if (todo.title == t && todo.estimatedMinutes > 0) return todo.estimatedMinutes;
        }
        return 5;
      },
    );
  }

  /// 일정이 없을 때 보여 주는 시연 경로 (안암역 → 청량리역, 내장 카카오 샘플 + 시연 계획)
  late final List<RouteCandidate> _demoRoutes = _routeApi.demoRoutes();
  String? _demoSelected;

  Widget _demoPlanner() {
    final ctx = OfflineDemoData.context;
    final sched = ctx['schedule'] is Map ? ctx['schedule'] as Map : const {};
    final loc = ctx['location'] is Map ? ctx['location'] as Map : const {};
    final dest = sched['destination'] is Map ? sched['destination'] as Map : const {};
    LatLng? ll(Map m) => m['lat'] is num && m['lng'] is num
        ? LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()) : null;
    final todos = TodoScope.of(context).todos;
    return MoveRoutePlanner(
      routes: _demoRoutes,
      selectedId: _demoSelected ?? (_demoRoutes.isEmpty ? null : _demoRoutes.first.id),
      onSelect: (id) => setState(() => _demoSelected = id),
      plan: ServerPlan(OfflineDemoData.plan),
      title: '청량리역 가기',
      badge: '시연',
      originName: '${loc['name'] ?? '안암역3번출구 정류장'}',
      destinationName: '${dest['name'] ?? '청량리역'}',
      arriveBy: DateTime.tryParse('${sched['arrive_by'] ?? ''}'),
      now: DateTime.tryParse('${ctx['now'] ?? ''}') ?? DateTime.now(),
      isDemo: true,
      origin: ll(loc),
      destination: ll(dest),
      onManageSchedule: widget.onOpenPlanner,
      onOpenAssistant: widget.onOpenAssistant,
      fallbackNeed: (t) {
        for (final todo in todos) {
          if (todo.title == t && todo.estimatedMinutes > 0) return todo.estimatedMinutes;
        }
        return 5;
      },
    );
  }

  String _time(DateTime value) => '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = ScheduleScope.of(context);
    final schedule = _explicitSchedule ?? _nextSchedule(controller.schedules);
    final scheduleKey = schedule == null ? null :
        '${schedule.id}|${schedule.location}|${schedule.startTime.toIso8601String()}|'
        '${schedule.destinationLatitude}|${schedule.destinationLongitude}|'
        '${schedule.originMode}|${schedule.originLatitude}|${schedule.originLongitude}|'
        '${schedule.preparationMinutes}';
    if (scheduleKey != _scheduleKey) {
      _scheduleKey = scheduleKey;
      _destinationLookupSerial++;
      _scheduleDestination = null;
      _destinationLookupMessage = null;
      _scheduleRequestSerial++;
      _scheduleError = null;
      _manualIsActive = false;
      _locationError = null;
      // Do not reuse the previous schedule's origin.
      _origin = null;
      _originController.clear();
      if (schedule != null && schedule.originMode == 'place' &&
          schedule.originLatitude != null && schedule.originLongitude != null) {
        _origin = Place(
          id: schedule.originPlaceId ?? '',
          name: schedule.originName ?? '선택한 출발지',
          address: schedule.originAddress ?? '',
          latitude: schedule.originLatitude!,
          longitude: schedule.originLongitude!,
        );
        _originController.text = _origin!.name;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _scheduleKey != scheduleKey) return;
        activeRouteController.clearSearch();
      });
      if (schedule != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _scheduleKey != scheduleKey) return;
          _resolveScheduleDestination(schedule);
          // GPS is requested only when the schedule uses current location.
          // A manually saved origin is never silently replaced with GPS.
          if (schedule.originMode != 'place' && _origin == null && !_autoLocating) {
            _autoLocating = true;
            _useCurrentLocation().whenComplete(() { _autoLocating = false; });
          } else if (_origin != null && _scheduleDestination != null) {
            _loadScheduleRoutes(schedule);
          }
        });
      }
    }
    // 이동 = 일정(또는 검색한 목적지) 기준 추천 경로 + 대안 비교 + 할 일 적용
    return Scaffold(
      appBar: AppBar(title: const Text('이동 · 경로 추천')),
      body: AnimatedBuilder(animation: activeRouteController, builder: (context, _) {
        final active = activeRouteController.active;
        return ListView(padding: const EdgeInsets.all(16), children: [
        if (active != null) ...[
          Row(children: [
            Expanded(child: Text(_manualIsActive ? '직접 검색한 이동 경로' : '다음 일정의 추천 경로',
                style: Theme.of(context).textTheme.titleLarge)),
            TextButton.icon(onPressed: () {
              activeRouteController.clearSearch();
              _manualIsActive = false;
              if (schedule != null) {
                if (_origin == null) {
                  _useCurrentLocation();
                } else if (_scheduleDestination != null) {
                  _loadScheduleRoutes(schedule);
                } else {
                  _resolveScheduleDestination(schedule);
                }
              }
            }, icon: const Icon(Icons.refresh), label: const Text('다음 일정 경로')),
          ]),
          _routePanel(routes: active.routes, selectedId: active.selectedId,
            onSelect: activeRouteController.select, loading: false, error: null,
            originName: active.origin, destinationName: active.destination,
            arrival: active.arrival, selection: active,
            title: _manualIsActive ? null : schedule?.title,
            origin: _manualIsActive ? _manualOrigin : _origin,
            destination: _manualIsActive ? _manualDestination : _scheduleDestination),
        ] else if (schedule == null && !ApiConfig.demoMode) ...[
          const Card(child: Padding(padding: EdgeInsets.all(18),
            child: Text('등록된 미래 일정이 없습니다. 일정 탭에서 목적지와 도착 시간을 등록하면 실제 경로를 계산할 수 있어요.'))),
        ] else if (schedule == null) ...[
          Card(child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.info_outline, color: Color(0xFF4936D8)),
                const SizedBox(width: 8),
                const Expanded(child: Text('예시 데이터입니다!',
                  style: TextStyle(fontWeight: FontWeight.bold))),
                Chip(label: const Text('DEMO'),
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest),
              ]),
              const SizedBox(height: 6),
              const Text('등록된 미래 일정이 없어 예시 이동 경로를 보여드립니다. '
                '실제 현재 위치나 실시간 운행을 기준으로 계산한 경로가 아닙니다.'),
              const SizedBox(height: 5),
              const Text('일정을 등록하면 현재 위치 → 다음 일정 목적지 경로로 자동 전환됩니다.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            ]),
          )),
          const SizedBox(height: 10),
          _demoPlanner(),
        ] else ...[
          Text('다음 일정 · 자동 경로', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(schedule.title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 5),
              Text('${_origin?.name ?? (schedule.originMode == 'place' ? '등록한 출발지' : '현재 위치')} → ${schedule.location}'),
              Text('도착 목표 ${_time(schedule.startTime)}'),
              if (_loadingSchedule || _locating || _resolvingDestination)
                const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
              if (_locationError != null)
                Text(_locationError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (_destinationLookupMessage != null)
                Text(_destinationLookupMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              if (_scheduleError != null)
                Text('자동 경로 조회 실패: $_scheduleError',
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
              const SizedBox(height: 8),
              if (schedule.originMode == 'current')
                OutlinedButton.icon(
                  onPressed: _locating ? null : _useCurrentLocation,
                  icon: const Icon(Icons.my_location),
                  label: Text(_locating ? '현재 위치 확인 중' : '현재 위치에서 경로 다시 찾기'),
                )
              else
                OutlinedButton.icon(
                  onPressed: () => _resolveScheduleDestination(schedule),
                  icon: const Icon(Icons.route),
                  label: const Text('저장된 출발지로 경로 다시 찾기'),
                ),
              if (_scheduleDestination == null && !_resolvingDestination)
                TextButton(onPressed: () => _resolveScheduleDestination(schedule),
                  child: const Text('일정 목적지 다시 검색')),
            ],
          ))),
          Text(schedule.originMode == 'current'
              ? '현재 위치 권한과 서버의 일반 경로 탐색 지원이 필요합니다. 시연 경로로 대체하지 않습니다.'
              : '등록된 출발지와 목적지로 실제 경로를 요청합니다. 서버에서 일반 경로 탐색을 지원해야 합니다.',
            style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ],
        const SizedBox(height: 22),
        const Divider(),
        ListTile(contentPadding: EdgeInsets.zero, title: const Text('별도 이동 계획 설정'), subtitle: const Text('다른 업무나 장소로 이동할 경로를 따로 검색합니다.'), trailing: Icon(_manualExpanded ? Icons.expand_less : Icons.expand_more), onTap: () => setState(() => _manualExpanded = !_manualExpanded)),
        if (_manualExpanded) ...[
          const SizedBox(height: 8),
          TextField(controller: _manualOriginController, readOnly: true, onTap: () => _pickManualPlace(origin: true), decoration: InputDecoration(labelText: '출발지', prefixIcon: const Icon(Icons.my_location), suffixIcon: IconButton(onPressed: () => _pickManualPlace(origin: true), icon: const Icon(Icons.search)), border: const OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: _manualDestinationController, readOnly: true, onTap: () => _pickManualPlace(origin: false), decoration: InputDecoration(labelText: '목적지', prefixIcon: const Icon(Icons.place), suffixIcon: IconButton(onPressed: () => _pickManualPlace(origin: false), icon: const Icon(Icons.search)), border: const OutlineInputBorder())),
          const SizedBox(height: 12),
          OutlinedButton.icon(onPressed: _pickManualArrival, icon: const Icon(Icons.schedule), label: Text(_manualArrival == null ? '도착 희망시간 선택' : _time(_manualArrival!))),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: _loadingManual ? null : _loadManualRoutes, icon: const Icon(Icons.route), label: Text(_loadingManual ? '검색 중...' : '이동 경로 검색')),
          if (_manualError != null || _loadingManual) ...[
            const SizedBox(height: 12),
            if (_loadingManual) const LinearProgressIndicator(),
            if (_manualError != null) Text(_manualError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
        if (widget.selectedWaypoint != null)
          ValueListenableBuilder<TodoItem?>(valueListenable: widget.selectedWaypoint!, builder: (_, todo, __) => todo == null ? const SizedBox.shrink() : Card(child: ListTile(title: Text('선택한 할 일: ${todo.title}'), subtitle: const Text('경유지 자동 검색은 아직 연결되지 않았습니다.'), trailing: IconButton(onPressed: () => widget.selectedWaypoint!.value = null, icon: const Icon(Icons.close))))),
        const SizedBox(height: 24),
        const Text('일정이 없을 때만 예시 경로가 표시됩니다. 실제 일정의 경로는 기기 위치와 서버 지원 여부에 따라 조회합니다.', style: TextStyle(color: Colors.grey)),
      ]);
      }),
    );
  }

  @override
  void dispose() {
    activeRouteController.removeListener(_handlePlanRefresh);
    widget.requestedSchedule?.removeListener(_handleRequestedSchedule);
    widget.requestedDestination?.removeListener(_handleRequestedDestination);
    _scheduleRequestSerial++;
    _destinationLookupSerial++;
    _manualRequestSerial++;
    _originController.dispose();
    _manualOriginController.dispose();
    _manualDestinationController.dispose();
    super.dispose();
  }
}
