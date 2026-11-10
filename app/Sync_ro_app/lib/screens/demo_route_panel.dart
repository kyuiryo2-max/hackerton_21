import 'package:flutter/material.dart';
import '../config/api_config.dart';
import '../data/demo_route_options.dart';
import '../data/demo_transit_geometry.dart';
import '../data/demo_route_style.dart';
import '../services/demo_service.dart';
import 'route_inline_map.dart';

/// Search-style route recommendations using bundled Kakao sample routes.
/// Only 2115 arrival times are sourced from the bundled arrival demo.
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
  int _selected = 0;
  bool _showDetails = false;

  @override
  void initState() { super.initState(); _refresh(); }

  Map<String, dynamic> _map(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : {};
  String _clock(dynamic value) {
    final dt = DateTime.tryParse('$value');
    if (dt == null) return '-';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final ctx = await _service.getContext();
      final stopId = '${_map(ctx['stop'])['ars_id'] ?? '08301'}';
      final arrivals = await _service.getArrivals(stopId: stopId, elapsedSeconds: _elapsedSeconds);
      if (mounted) setState(() { _context = ctx; _arrivals = arrivals; });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _locationRow(IconData icon, Color color, String title, String subtitle) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, color: color, size: 20)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 12)),
        ])),
      ]);

  Widget _modePill(String mode, String label, {String? rawLabel}) {
    final color = DemoRouteStyle.colorFor(mode, rawLabel ?? label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(DemoRouteStyle.iconFor(mode), size: 15, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
    );
  }

  Widget _legDetails(DemoRouteOption option) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE7E7EA)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('구간별 이동 안내', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text('구간의 시작·끝 지점은 시연 경로 샘플 기준입니다.',
          style: TextStyle(fontSize: 11, color: Colors.black54)),
        const SizedBox(height: 12),
        for (var i = 0; i < option.legs.length; i++) ...[
          _legRow(option.legs[i]),
          if (i != option.legs.length - 1) const Divider(height: 18, indent: 34),
        ],
      ]),
    );
  }

  Widget _legRow(DemoRouteLeg leg) {
    final color = DemoRouteStyle.colorFor(leg.mode, leg.label);
    final endpoints = DemoRouteStyle.endpoints(leg);
    final min = (leg.seconds / 60).ceil();
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 28, height: 28,
        decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(8)),
        child: Icon(DemoRouteStyle.iconFor(leg.mode), size: 17, color: color),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(DemoRouteStyle.nameFor(leg),
            style: TextStyle(fontWeight: FontWeight.w800, color: color, fontSize: 14))),
          Text('약 $min분', style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Icon(Icons.radio_button_checked, size: 12, color: color),
          const SizedBox(width: 7),
          Expanded(child: Text(endpoints.$1, style: const TextStyle(fontSize: 13))),
        ]),
        Padding(padding: const EdgeInsets.only(left: 5), child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          width: 2, height: 13, color: color.withValues(alpha: 0.45),
        )),
        Row(children: [
          Icon(Icons.location_on_outlined, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(child: Text(endpoints.$2, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
        ]),
      ])),
    ]);
  }

  Widget _optionCard(int index) {
    final option = DemoRouteOptions.routes[index];
    final selected = index == _selected;
    final minutes = (option.durationSeconds / 60).ceil();
    final primaryTime = index == 0 && _arrivals != null
        ? 16 + (_arrivals!.where((a) => a.route == '2115').isEmpty
            ? 12 : _arrivals!.firstWhere((a) => a.route == '2115').minutes)
        : minutes;
    return InkWell(
      onTap: () => setState(() { _selected = index; _showDetails = false; }),
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFF4F2FF) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? const Color(0xFF4936D8) : const Color(0xFFE5E5E8), width: selected ? 1.7 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (index == 0) ...[
              const Icon(Icons.stars_rounded, size: 17, color: Color(0xFF4936D8)),
              const SizedBox(width: 4),
              const Text('추천', style: TextStyle(fontSize: 12, color: Color(0xFF4936D8), fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(option.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 21, color: selected ? const Color(0xFF4936D8) : Colors.grey),
          ]),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('$primaryTime', style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w800)),
            const Padding(padding: EdgeInsets.only(bottom: 3), child: Text('분', style: TextStyle(fontSize: 14))),
            const SizedBox(width: 8),
            Expanded(child: Text(index == 0 && _arrivals != null ? '시연 대기 포함 · 이동 약 16분' : '이동 예상 · 대기시간 제외',
                style: const TextStyle(fontSize: 11, color: Colors.black54))),
            Text('${option.fare}원', style: const TextStyle(fontSize: 12, color: Colors.black87)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 5, runSpacing: 5, children: [
            for (final leg in option.legs)
              _modePill(leg.mode, DemoRouteStyle.nameFor(leg), rawLabel: leg.label),
            Text('환승 ${option.transfers}회', style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _context ?? {};
    final location = _map(ctx['location']);
    final schedule = _map(ctx['schedule']);
    final destination = _map(schedule['destination']);
    final stop = _map(ctx['stop']);
    final option = DemoRouteOptions.routes[_selected];
    final bus2115 = _arrivals?.where((a) => a.route == '2115');
    final arrival2115 = bus2115 != null && bus2115.isNotEmpty ? bus2115.first : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(padding: const EdgeInsets.all(17), decoration: BoxDecoration(color: Colors.white,
        borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFEAE9EE))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('이동 경로 찾기', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 19))),
            const Icon(Icons.science_outlined, color: Color(0xFF4936D8), size: 18),
            const SizedBox(width: 3),
            const Text('시연', style: TextStyle(color: Color(0xFF4936D8), fontWeight: FontWeight.w700)),
            IconButton(tooltip: '시연 새로고침', onPressed: _loading ? null : _refresh, icon: const Icon(Icons.refresh)),
          ]),
          const SizedBox(height: 8),
          _locationRow(Icons.trip_origin, const Color(0xFF4936D8), '${location['name'] ?? '안암역3번출구'}', '출발'),
          const Padding(padding: EdgeInsets.only(left: 9), child: SizedBox(height: 22, child: VerticalDivider(thickness: 1.5))),
          _locationRow(Icons.location_on, Colors.redAccent, '${destination['name'] ?? '청량리역'}', '도착'),
          const Divider(height: 25),
          Wrap(spacing: 12, runSpacing: 7, children: [
            Text('기준 ${_clock(ctx['now'])}', style: const TextStyle(fontWeight: FontWeight.w600)),
            Text('도착 마감 ${_clock(schedule['arrive_by'])}', style: const TextStyle(color: Color(0xFF4936D8), fontWeight: FontWeight.w700)),
            const Text('고정된 시연 날짜', style: TextStyle(color: Colors.black45, fontSize: 12)),
          ]),
        ])),
      const SizedBox(height: 14),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Text('시연 데이터를 불러올 수 없습니다: $_error', style: const TextStyle(color: Colors.red)),
      if (_context != null) ...[
        Row(children: [
          const Expanded(child: Text('추천 경로 3개', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
          const Text('카카오 경로 샘플 기준', style: TextStyle(fontSize: 11, color: Colors.black54)),
        ]),
        const SizedBox(height: 9),
        for (var i = 0; i < DemoRouteOptions.routes.length; i++) _optionCard(i),
        const SizedBox(height: 5),
        Text('선택 경로 · ${option.label}',
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 7),
        Wrap(spacing: 6, runSpacing: 5, children: [
          for (final leg in option.legs)
            _modePill(leg.mode, DemoRouteStyle.nameFor(leg), rawLabel: leg.label),
        ]),
        const SizedBox(height: 9),
        SizedBox(height: 285, child: RouteInlineMap(
          key: ValueKey('demo-route-$_selected'),
          demoLegs: option.legs,
          demoStopNames: _selected == 0 ? DemoTransitGeometry.stopNames : null,
          demoStopPositions: _selected == 0 ? DemoTransitGeometry.stopPositions : null,
        )),
        const SizedBox(height: 7),
        const Text('실제 경로 좌표는 앱에 포함되어 있어요. 지도 배경은 인터넷이 필요합니다.',
          style: TextStyle(color: Colors.black54, fontSize: 11)),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => setState(() => _showDetails = !_showDetails),
          icon: Icon(_showDetails ? Icons.expand_less : Icons.expand_more),
          label: Text(_showDetails ? '경로 구간 정보 접기' : '구간별 출발·도착 정보 펼치기'),
        ),
        if (_showDetails) _legDetails(option),
        Card(color: const Color(0xFFF5F5F7), elevation: 0, child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('버스 도착 정보', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text('${stop['name'] ?? '안암역3번출구'} · ARS ${stop['ars_id'] ?? '08301'}',
              style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            SegmentedButton<int>(segments: const [
              ButtonSegment(value: 0, label: Text('시연 시작')),
              ButtonSegment(value: 600, label: Text('10분 경과')),
            ], selected: {_elapsedSeconds}, onSelectionChanged: _loading ? null : (v) {
              setState(() => _elapsedSeconds = v.first); _refresh();
            }),
            if (arrival2115 != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.directions_bus, color: Colors.green),
                const SizedBox(width: 7),
                Expanded(child: Text('2115번 ${arrival2115.minutes <= 0 ? '곧 도착' : '${arrival2115.minutes}분 후 도착'}',
                  style: const TextStyle(fontWeight: FontWeight.w700))),
                Text(arrival2115.nextMinutes == null ? '' : '다음 ${arrival2115.nextMinutes}분', style: const TextStyle(fontSize: 12)),
              ]),
            ],
            const SizedBox(height: 4),
            const Text('다른 경로의 대기시간과 도착 예측은 제공되지 않아요. 실시간 정보가 아닙니다.',
              style: TextStyle(fontSize: 11, color: Colors.black54)),
          ]))),
      ],
      if (!ApiConfig.offlineDemo) const Padding(padding: EdgeInsets.only(top: 8), child:
        Text('현재 화면은 서버와 별개의 시연 경로입니다.', style: TextStyle(color: Colors.black54))),
    ]);
  }

  @override
  void dispose() { _service.dispose(); super.dispose(); }
}
