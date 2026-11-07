import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/place.dart';
import '../models/route_candidate.dart';
import '../models/route_request.dart';
import '../models/schedule.dart';
import '../models/todo_item.dart';
import '../providers/schedule_controller.dart';
import '../services/route_api_service.dart';
import '../services/place_search_service.dart';
import 'place_search_screen.dart';
import 'route_inline_map.dart';

class NavigationScreen extends StatefulWidget {
  final ValueNotifier<TodoItem?>? selectedWaypoint;
  final String? initialDestination;
  final DateTime? initialArrivalTime;

  const NavigationScreen({super.key, this.selectedWaypoint, this.initialDestination, this.initialArrivalTime});

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
  List<RouteCandidate> _scheduleRoutes = [];
  List<RouteCandidate> _manualRoutes = [];
  String? _scheduleRouteId;
  String? _manualRouteId;
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

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _manualDestinationController.text = widget.initialDestination ?? '';
    _manualArrival = widget.initialArrivalTime;
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

  Future<void> _pickOrigin() async {
    final place = await _pickPlace('일정 출발지 검색');
    if (!mounted || place == null) return;
    setState(() { _origin = place; _originController.text = place.name; });
    final schedule = _nextSchedule(ScheduleScope.of(context).schedules);
    if (schedule != null) await _loadScheduleRoutes(schedule);
  }

  Future<void> _useCurrentLocation() async {
    if (_locating) return;
    setState(() { _locating = true; _locationError = null; });
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) throw Exception('기기 위치 서비스가 꺼져 있습니다.');
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw Exception('위치 권한이 허용되지 않았습니다.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      final place = Place(
        id: 'device_current_location', name: '현재 위치', address: '기기 위치',
        latitude: position.latitude, longitude: position.longitude,
      );
      setState(() { _origin = place; _originController.text = place.name; });
      final schedule = _nextSchedule(ScheduleScope.of(context).schedules);
      if (schedule != null && _scheduleDestination != null) {
        await _loadScheduleRoutes(schedule);
      }
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
      if (_origin != null) await _loadScheduleRoutes(schedule);
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
      if (chosen != null && _origin != null) await _loadScheduleRoutes(schedule);
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
    setState(() { _loadingSchedule = true; _scheduleError = null; _scheduleRoutes = []; });
    try {
      final routes = await _routeApi.searchRoutes(RouteRequest(
        origin: _origin!.name, destination: schedule.location,
        desiredArrivalTime: schedule.startTime, originPlace: _origin, destinationPlace: _scheduleDestination,
      ));
      if (!mounted || serial != _scheduleRequestSerial) return;
      setState(() { _scheduleRoutes = routes; _scheduleRouteId = routes.isEmpty ? null : routes.first.id; });
    } catch (e) {
      if (mounted && serial == _scheduleRequestSerial) setState(() => _scheduleError = '$e');
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
    setState(() { _loadingManual = true; _manualError = null; _manualRoutes = []; });
    try {
      final routes = await _routeApi.searchRoutes(RouteRequest(
        origin: _manualOriginController.text.trim(), destination: _manualDestinationController.text.trim(),
        desiredArrivalTime: _manualArrival!, originPlace: _manualOrigin, destinationPlace: _manualDestination,
      ));
      if (!mounted || serial != _manualRequestSerial) return;
      setState(() { _manualRoutes = routes; _manualRouteId = routes.isEmpty ? null : routes.first.id; });
    } catch (e) {
      if (mounted && serial == _manualRequestSerial) setState(() => _manualError = '$e');
    } finally {
      if (mounted && serial == _manualRequestSerial) setState(() => _loadingManual = false);
    }
  }

  RouteCandidate? _selected(List<RouteCandidate> routes, String? id) {
    if (routes.isEmpty) return null;
    for (final route in routes) { if (route.id == id) return route; }
    return routes.first;
  }

  void _compareRoutes(List<RouteCandidate> routes, String? selectedId, ValueChanged<String> onSelect) {
    showModalBottomSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (sheetContext) => SafeArea(child: FractionallySizedBox(
        heightFactor: 0.72,
        child: Column(children: [
          Padding(padding: const EdgeInsets.all(16), child: Text('추천 경로 비교', style: Theme.of(sheetContext).textTheme.titleLarge)),
          Expanded(child: ListView.builder(itemCount: routes.length, itemBuilder: (_, i) {
            final r = routes[i];
            return ListTile(
              selected: r.id == selectedId,
              leading: Icon(r.id == selectedId ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(r.title),
              subtitle: Text('총 ${r.totalMinutes}분 · 도보 ${r.walkingMinutes}분 · 대기 ${r.waitingMinutes}분 · 환승 ${r.transferCount}회'),
              trailing: r.isRecommended ? const Icon(Icons.star, color: Colors.amber) : null,
              onTap: () { onSelect(r.id); Navigator.pop(sheetContext); },
            );
          })),
        ]),
      )),
    );
  }

  Widget _routePanel({required List<RouteCandidate> routes, required String? selectedId, required ValueChanged<String> onSelect, required bool loading, required String? error, Place? origin, Place? destination}) {
    final selected = _selected(routes, selectedId);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(height: 350, child: RouteInlineMap(key: ValueKey('${selected?.id}-${origin?.id}-${destination?.id}'), candidate: selected, origin: origin, destination: destination)),
      const SizedBox(height: 12),
      if (loading) const LinearProgressIndicator(),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (selected != null) ...[
        Card(child: ListTile(
          title: Text(selected.title),
          subtitle: Text('총 ${selected.totalMinutes}분 · 도보 ${selected.walkingMinutes}분 · 대기 ${selected.waitingMinutes}분 · 환승 ${selected.transferCount}회'),
          trailing: const Icon(Icons.unfold_more),
          onTap: () => _compareRoutes(routes, selected.id, onSelect),
        )),
        for (final segment in selected.segments)
          ListTile(dense: true, leading: Icon(switch (segment.type) {
            RouteSegmentType.walking => Icons.directions_walk,
            RouteSegmentType.bus => Icons.directions_bus,
            RouteSegmentType.subway => Icons.train,
            RouteSegmentType.waiting => Icons.schedule,
          }), title: Text(segment.description), trailing: Text('${segment.durationMinutes}분')),
      ] else if (!loading && error == null)
        const Padding(padding: EdgeInsets.all(8), child: Text('경로가 아직 없습니다. 출발지를 선택해 탐색해 주세요.')),
    ]);
  }

  String _time(DateTime value) => '${value.month}/${value.day} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final controller = ScheduleScope.of(context);
    final schedule = _nextSchedule(controller.schedules);
    final scheduleKey = schedule == null ? null : '${schedule.id}|${schedule.location}|${schedule.startTime.toIso8601String()}';
    if (scheduleKey != _scheduleKey) {
      _scheduleKey = scheduleKey;
      _destinationLookupSerial++;
      _scheduleDestination = null;
      _destinationLookupMessage = null;
      _scheduleRequestSerial++;
      _scheduleRoutes = [];
      _scheduleRouteId = null;
      _scheduleError = null;
      if (schedule != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _scheduleKey == scheduleKey) _resolveScheduleDestination(schedule); });
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('이동')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text('가장 가까운 일정', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (schedule == null)
          const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('예정된 일정이 없습니다. 일정 탭에서 일정을 추가해 주세요.')))
        else ...[
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(schedule.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('목적지: ${schedule.location}  ·  시작: ${_time(schedule.startTime)}'),
          ]))),
          const SizedBox(height: 8),
          TextField(controller: _originController, readOnly: true, onTap: _pickOrigin,
            decoration: InputDecoration(labelText: '일정 출발지 선택', prefixIcon: const Icon(Icons.my_location), suffixIcon: IconButton(onPressed: _pickOrigin, icon: const Icon(Icons.search)), border: const OutlineInputBorder())),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
            onPressed: _locating ? null : _useCurrentLocation,
            icon: const Icon(Icons.gps_fixed),
            label: Text(_locating ? '위치 확인 중...' : '현재 위치를 출발지로 사용'),
          )),
          if (_locationError != null) Text(_locationError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (_resolvingDestination) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (_scheduleDestination != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text('확인된 목적지: ${_scheduleDestination!.name}')),
          if (_destinationLookupMessage != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_destinationLookupMessage!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 12),
          _routePanel(routes: _scheduleRoutes, selectedId: _scheduleRouteId, onSelect: (id) => setState(() => _scheduleRouteId = id), loading: _loadingSchedule, error: _scheduleError, origin: _origin, destination: _scheduleDestination),
          if (_origin != null) Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: _loadingSchedule ? null : () => _loadScheduleRoutes(schedule), icon: const Icon(Icons.refresh), label: const Text('경로 새로고침'))),
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
          if (_manualRoutes.isNotEmpty || _manualError != null || _loadingManual) ...[
            const SizedBox(height: 12),
            _routePanel(routes: _manualRoutes, selectedId: _manualRouteId, onSelect: (id) => setState(() => _manualRouteId = id), loading: _loadingManual, error: _manualError, origin: _manualOrigin, destination: _manualDestination),
          ],
        ],
        if (widget.selectedWaypoint != null)
          ValueListenableBuilder<TodoItem?>(valueListenable: widget.selectedWaypoint!, builder: (_, todo, __) => todo == null ? const SizedBox.shrink() : Card(child: ListTile(title: Text('선택한 할 일: ${todo.title}'), subtitle: const Text('경유지 자동 검색은 아직 연결되지 않았습니다.'), trailing: IconButton(onPressed: () => widget.selectedWaypoint!.value = null, icon: const Icon(Icons.close))))),
        const SizedBox(height: 24),
        const Text('장소 검색은 API 설정에 따라 샘플 또는 실제 검색입니다. 경로 검색은 별도 설정이며 샘플 모드에서는 선택한 위치와 무관한 테스트 경로가 나올 수 있습니다.', style: TextStyle(color: Colors.grey)),
      ]),
    );
  }

  @override
  void dispose() {
    _scheduleRequestSerial++;
    _destinationLookupSerial++;
    _manualRequestSerial++;
    _originController.dispose();
    _manualOriginController.dispose();
    _manualDestinationController.dispose();
    super.dispose();
  }
}
