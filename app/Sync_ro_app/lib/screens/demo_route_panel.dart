import 'package:flutter/material.dart';
import '../models/place.dart';
import '../config/api_config.dart';
import '../data/offline_demo_data.dart';
import 'offline_route_diagram.dart';
import '../services/demo_service.dart';
import 'route_inline_map.dart';

/// Demonstration-only UI; never uses mock route geometry as if it came from the server.
class DemoRoutePanel extends StatefulWidget {
  const DemoRoutePanel({super.key});
  @override
  State<DemoRoutePanel> createState() => _DemoRoutePanelState();
}

class _DemoRoutePanelState extends State<DemoRoutePanel> {
  final DemoService _service = DemoService();
  Map<String, dynamic>? _context;
  List<BusArrival>? _arrivals;
  String? _error;
  bool _loading = false;
  int _elapsedSeconds = 0;

  @override
  void initState() { super.initState(); _refresh(); }

  Map<String, dynamic> _object(dynamic v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  double? _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v');
  String _displayDate(dynamic v) {
    final parsed = DateTime.tryParse('$v');
    return parsed == null ? '$v' : '${parsed.month}/${parsed.day} ${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}';
  }
  Place? _place(Map<String, dynamic> raw, String id) {
    final lat = _num(raw['lat'] ?? raw['latitude']);
    final lng = _num(raw['lng'] ?? raw['longitude']);
    if (lat == null || lng == null) return null;
    return Place(id: id, name: '${raw['name'] ?? id}', address: '', latitude: lat, longitude: lng);
  }
  Future<void> _refresh() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final ctx = await _service.getContext();
      final stopId = '${_object(ctx['stop'])['ars_id'] ?? '08301'}';
      final arrivals = await _service.getArrivals(stopId: stopId, elapsedSeconds: _elapsedSeconds);
      if (!mounted) return;
      setState(() { _context = ctx; _arrivals = arrivals; });
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; });
    } finally {
      if (mounted) setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _context ?? {};
    final location = _object(ctx['location']);
    final schedule = _object(ctx['schedule']);
    final route = _object(ctx['route']);
    final stop = _object(ctx['stop']);
    final origin = _place(location, 'demo-origin');
    final destination = _place(_object(schedule['destination']), 'demo-destination');
    final stops = route['stops'] is List ? route['stops'] as List : <dynamic>[];
    final movingMinutes = ((route['moving_seconds'] as num?)?.toDouble() ?? 0) / 60;
    final lastWalkMinutes = ((route['last_walk_seconds'] as num?)?.toDouble() ?? 0) / 60;

    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(ApiConfig.offlineDemo ? '오프라인 시연 경로 · 버스 도착' : '서버 시연 경로 · 버스 도착', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold))),
        IconButton(tooltip: '시연 데이터 새로고침', onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh)),
      ]),
      const Text('시연 데이터는 고정된 날짜와 정류장 기준이며 실시간 운행정보가 아닙니다.', style: TextStyle(color: Colors.black54)),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('시연 데이터 오류: $_error', style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (_context != null) ...[
        const SizedBox(height: 8),
        Text('기준 시각: ${_displayDate(ctx['now'])}  ·  도착 마감: ${_displayDate(schedule['arrive_by'])}'),
        Text('출발: ${location['name'] ?? '-'} → 도착: ${_object(schedule['destination'])['name'] ?? '-'}'),
        Text('버스 ${route['name'] ?? '-'} · ${route['guidance'] ?? ''}'),
        Text('차량 이동 약 ${movingMinutes.ceil()}분 · 마지막 도보 약 ${lastWalkMinutes.ceil()}분 · 환승 ${route['transfers'] ?? '-'}회'),
        const SizedBox(height: 10),
        if (origin != null && destination != null) ...[
          const Text('이동 경로 지도', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          SizedBox(height: 260, child: RouteInlineMap(origin: origin, destination: destination)),
          const SizedBox(height: 6),
          const Text('지도 배경은 인터넷이 필요합니다. 출발·도착 핀은 시연 JSON의 실제 좌표입니다. 중간 정류장 좌표와 도로 경로선은 제공되지 않았습니다.',
            style: TextStyle(fontSize: 12, color: Colors.black54)),
        ],
        if (ApiConfig.offlineDemo && stops.isNotEmpty) ...[
          const SizedBox(height: 12),
          OfflineRouteDiagram(stops: stops),
        ],
        if (!ApiConfig.offlineDemo && stops.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('경유 정류장', style: TextStyle(fontWeight: FontWeight.bold)),
          for (var i = 0; i < stops.length; i++)
            Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
              Icon(i == 0 ? Icons.trip_origin : i == stops.length - 1 ? Icons.flag : Icons.more_vert, size: 18),
              const SizedBox(width: 8), Expanded(child: Text('${i + 1}. ${stops[i]}')),
            ])),
        ],
        if (ApiConfig.offlineDemo) ...[
          const SizedBox(height: 8),
          const Divider(),
          const Text('일정과 할 일 추천 · 시연 결과',
            style: TextStyle(fontWeight: FontWeight.bold)),
          Text('${OfflineDemoData.plan['explanation'] ?? ''}'),
          for (final item in (OfflineDemoData.plan['todos'] as List))
            ListTile(dense: true, contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.checklist),
              title: Text('${item['text']} · ${item['status']}'),
              subtitle: Text('${(item['place'] as Map?)?['name'] ?? ''}'
                  '${item['reason'] == null || item['reason'] == '' ? '' : ' · ${item['reason']}'}')),
        ],
        const Divider(),
        Text('정류장: ${stop['name'] ?? '-'} (ARS ${stop['ars_id'] ?? '08301'})', style: const TextStyle(fontWeight: FontWeight.bold)),
        Row(children: [
          const Text('시연 경과: '),
          DropdownButton<int>(value: _elapsedSeconds, items: const [
            DropdownMenuItem(value: 0, child: Text('0분')),
            DropdownMenuItem(value: 600, child: Text('10분')),
          ], onChanged: _loading ? null : (v) { if (v != null) { setState(() => _elapsedSeconds = v); _refresh(); } }),
        ]),
        if (_arrivals != null)
          for (final bus in _arrivals!) ListTile(
            contentPadding: EdgeInsets.zero, dense: true,
            leading: const Icon(Icons.directions_bus),
            title: Text('${bus.route}번 · ${bus.minutes <= 0 ? '곧 도착' : '${bus.minutes}분 후 도착'}'),
            subtitle: Text('방면: ${bus.direction}'),
            trailing: bus.nextMinutes == null ? null : Text('다음 ${bus.nextMinutes}분'),
          ),
      ] else if (!_loading) const Text('새로고침을 눌러 시연 데이터를 불러오세요.'),
    ])));
  }
  @override
  void dispose() { _service.dispose(); super.dispose(); }
}
