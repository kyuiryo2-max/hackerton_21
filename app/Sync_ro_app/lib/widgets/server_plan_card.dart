import 'package:flutter/material.dart';
import '../config/api_config.dart';
import '../models/place.dart';
import '../models/route_candidate.dart';
import '../screens/search_route_results_panel.dart';
import '../services/demo_service.dart';
import '../services/server_plan_service.dart';
import '../services/server_route_adapter.dart';
import '../providers/active_route_controller.dart';

/// Server-backed sample plan. UI is shared with ordinary route search results.
/// Never substitutes bundled routes when the backend fails.
class ServerPlanCard extends StatefulWidget {
  const ServerPlanCard({super.key});
  @override
  State<ServerPlanCard> createState() => _ServerPlanCardState();
}

class _ServerPlanCardState extends State<ServerPlanCard> {
  final _planService = ServerPlanService();
  final _demoService = DemoService();
  ServerPlan? _plan;
  Map<String, dynamic>? _context;
  String? _error;
  String? _contextWarning;
  bool _loading = false;
  String? _selectedRouteId;

  @override
  void initState() {
    super.initState();
    activeRouteController.addListener(_onPlanChanged);
    _load();
  }

  int _lastRevision = activeRouteController.revision;
  void _onPlanChanged() {
    if (_lastRevision == activeRouteController.revision) return;
    _lastRevision = activeRouteController.revision;
    _load();
  }

  Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};

  Place? _place(dynamic value) {
    final v = _map(value);
    final lat = v['lat'] ?? v['latitude'];
    final lng = v['lng'] ?? v['longitude'];
    if (lat is! num || lng is! num) return null;
    return Place(
      id: '${v['ars_id'] ?? v['todo_id'] ?? v['name'] ?? ''}',
      name: '${v['name'] ?? '위치'}', address: '${v['address'] ?? ''}',
      latitude: lat.toDouble(), longitude: lng.toDouble(),
    );
  }

  List<Place> _places(dynamic value) {
    if (value is! List) return const [];
    return value.map(_place).whereType<Place>().toList();
  }

  DateTime? _date(dynamic value) => DateTime.tryParse('$value');
  Future<void> _load() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; _contextWarning = null; });
    try {
      final plan = await _planService.fetch();
      Map<String, dynamic>? context;
      String? warning;
      if (ApiConfig.demoMode) {
        try {
          context = await _demoService.getContext();
        } catch (e) {
          warning = '지도 좌표 조회 실패: $e';
        }
      }
      if (mounted) {
        setState(() {
          _plan = plan;
          _context = context;
          _contextWarning = warning;
          _selectedRouteId = plan.routes.isEmpty ? null :
              'server_${plan.routes.first['rank'] ?? 1}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() { _error = '$e'; _plan = null; _context = null; });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    activeRouteController.removeListener(_onPlanChanged);
    _planService.dispose();
    _demoService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final ctx = _context ?? <String, dynamic>{};
    final schedule = _map(ctx['schedule'] ?? plan?.data['schedule']);
    final origin = _place(ctx['location']);
    final destination = _place(schedule['destination']);
    final route = _map(ctx['route']);
    final stopPoints = _places(route['stop_points']);
    final nearby = _places(ctx['places']);
    final routes = plan == null ? <RouteCandidate>[] : [
      for (var i = 0; i < plan.routes.length; i++)
        ServerRouteAdapter.fromPlan(plan.routes[i], i, context: _context),
    ];
    final hasMatchedGeometry = routes.any((r) =>
        r.segments.any((leg) => leg.geometry.isNotEmpty));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text('추천 이동 계획', style: Theme.of(context).textTheme.titleLarge)),
        if (ApiConfig.demoMode) const Chip(label: Text('서버 시연')),
        IconButton(tooltip: '서버에서 다시 조회', onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh)),
      ]),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Card(child: Padding(padding: const EdgeInsets.all(14),
          child: Text('서버 계획 조회 실패: $_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error)))),
      if (_contextWarning != null)
        Text(_contextWarning!, style: const TextStyle(fontSize: 12, color: Colors.deepOrange)),
      if (plan != null) ...[
        SearchRouteResultsPanel(
          routes: routes,
          selectedId: _selectedRouteId,
          onSelect: (id) => setState(() => _selectedRouteId = id),
          origin: origin,
          destination: destination,
          originName: origin?.name ?? '출발 위치 정보 미제공',
          destinationName: destination?.name ?? '목적지 정보 미제공',
          desiredArrival: _date(schedule['arrive_by']),
          referenceTime: _date(plan.data['now'] ?? ctx['now']),
          serverDemo: ApiConfig.demoMode,
          plan: plan,
          routeStops: hasMatchedGeometry ? stopPoints : const [],
          nearbyPlaces: hasMatchedGeometry ? nearby : const [],
        ),
        if (ApiConfig.demoMode)
          const Text('서버의 고정 시연 시나리오입니다. 현재 실시간 경로는 아닙니다.',
            style: TextStyle(color: Colors.black54, fontSize: 11)),
      ],
    ]);
  }
}
