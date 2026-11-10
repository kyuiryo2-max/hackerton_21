import 'package:flutter/material.dart';

import '../data/demo_route_style.dart';
import '../models/place.dart';
import '../models/route_candidate.dart';
import 'route_inline_map.dart';
import '../services/server_plan_service.dart';
import '../widgets/plan_details_panel.dart';

/// Search results use the same card / map / expanded-leg layout as the demo.
/// This widget never substitutes demo coordinates for a user's searched route.
class SearchRouteResultsPanel extends StatefulWidget {
  final List<RouteCandidate> routes;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final Place? origin;
  final Place? destination;
  final String originName;
  final String destinationName;
  final DateTime? desiredArrival;
  final DateTime? referenceTime;
  final List<Place> routeStops;
  final List<Place> nearbyPlaces;
  final bool serverDemo;
  final ServerPlan? plan;
  final bool loading;
  final String? error;

  const SearchRouteResultsPanel({
    super.key,
    required this.routes,
    required this.selectedId,
    required this.onSelect,
    required this.originName,
    required this.destinationName,
    this.origin,
    this.destination,
    this.desiredArrival,
    this.referenceTime,
    this.routeStops = const [],
    this.nearbyPlaces = const [],
    this.serverDemo = false,
    this.plan,
    this.loading = false,
    this.error,
  });

  @override
  State<SearchRouteResultsPanel> createState() => _SearchRouteResultsPanelState();
}

class _SearchRouteResultsPanelState extends State<SearchRouteResultsPanel> {
  bool _expanded = false;

  RouteCandidate? get _selected {
    if (widget.routes.isEmpty) return null;
    for (final route in widget.routes) {
      if (route.id == widget.selectedId) return route;
    }
    return widget.routes.first;
  }

  String _clock(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _mode(RouteSegment segment) => switch (segment.type) {
    RouteSegmentType.walking => 'WALKING',
    RouteSegmentType.bus => 'BUS',
    RouteSegmentType.subway => 'SUBWAY',
    RouteSegmentType.waiting => 'WAITING',
  };

  Color _color(RouteSegment s) => s.type == RouteSegmentType.waiting
      ? DemoRouteStyle.walking
      : DemoRouteStyle.colorFor(_mode(s), '${s.lineName ?? ''} ${s.description}');

  IconData _icon(RouteSegment s) => s.type == RouteSegmentType.waiting
      ? Icons.schedule : DemoRouteStyle.iconFor(_mode(s));

  String _label(RouteSegment s) {
    if (s.lineName?.trim().isNotEmpty == true) return s.lineName!;
    if (s.type == RouteSegmentType.subway) {
      final n = DemoRouteStyle.subwayNumber(s.description);
      return n == null ? '지하철' : '$n호선';
    }
    if (s.type == RouteSegmentType.bus) {
      final n = RegExp(r'\b\d{2,4}\b').firstMatch(s.description);
      return n == null ? '버스' : '${n.group(0)}번 버스';
    }
    return switch (s.type) {
      RouteSegmentType.walking => '도보',
      RouteSegmentType.waiting => '대기',
      _ => '대중교통',
    };
  }

  (String, String) _endpoints(RouteSegment s, int index, List<RouteSegment> legs) {
    if (s.startName?.trim().isNotEmpty == true && s.endName?.trim().isNotEmpty == true) {
      return (s.startName!, s.endName!);
    }
    // Recognize actual route API descriptions of the form 'A → B' / 'A > B'.
    final match = RegExp(r'(.+?)\s*(?:→|->| > )\s*(.+)').firstMatch(s.description);
    if (match != null) return (s.startName ?? match.group(1)!.trim(), s.endName ?? match.group(2)!.trim());
    final previous = index == 0 ? widget.originName : legs[index - 1].endName;
    final next = index == legs.length - 1 ? widget.destinationName : null;
    return (s.startName ?? previous ?? '구간 시작 위치 미제공', s.endName ?? next ?? '구간 도착 위치 미제공');
  }

  Widget _chip(RouteSegment s) {
    final color = _color(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: .10), borderRadius: BorderRadius.circular(8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(_icon(s), size: 15, color: color),
        const SizedBox(width: 4),
        Text(_label(s), style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _card(RouteCandidate r, int index) {
    final active = _selected?.id == r.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: active ? const Color(0xFFF4F2FF) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(15),
          side: BorderSide(color: active ? const Color(0xFF4936D8) : const Color(0xFFE5E5E8), width: active ? 1.7 : 1),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(15),
          onTap: () { widget.onSelect(r.id); setState(() => _expanded = false); },
          child: Padding(padding: const EdgeInsets.all(14), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                if (r.isRecommended || index == 0) ...[
                  const Icon(Icons.stars_rounded, color: Color(0xFF4936D8), size: 17),
                  const SizedBox(width: 5),
                ],
                Expanded(child: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15))),
                Icon(active ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: active ? const Color(0xFF4936D8) : Colors.grey),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Text('${r.totalMinutes}분', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 24)),
                const SizedBox(width: 8),
                Expanded(child: Text('도보 ${r.walkingMinutes}분 · 대기 ${r.waitingMinutes}분 · 환승 ${r.transferCount}회',
                    style: const TextStyle(fontSize: 11, color: Colors.black54))),
              ]),
              const SizedBox(height: 9),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final leg in r.segments.where((s) => s.type != RouteSegmentType.waiting)) _chip(leg),
              ]),
            ],
          )),
        ),
      ),
    );
  }

  Widget _details(RouteCandidate route) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFE7E7EA)), borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('구간별 이동 안내', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 5),
        const Text('위치명이 없는 구간은 API 데이터가 제공하는 범위까지만 표시합니다.', style: TextStyle(color: Colors.black54, fontSize: 11)),
        const SizedBox(height: 12),
        for (var i = 0; i < route.segments.length; i++) ...[
          _leg(route.segments[i], i, route.segments),
          if (i < route.segments.length - 1) const Divider(height: 22, indent: 32),
        ],
      ]),
    );
  }

  Widget _leg(RouteSegment s, int i, List<RouteSegment> legs) {
    final color = _color(s);
    final endpoints = _endpoints(s, i, legs);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(width: 29, height: 29,
        decoration: BoxDecoration(color: color.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
        child: Icon(_icon(s), color: color, size: 18)),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_label(s), style: TextStyle(color: color, fontWeight: FontWeight.w800))),
          Text('${s.durationMinutes}분', style: const TextStyle(color: Colors.black54, fontSize: 12)),
        ]),
        const SizedBox(height: 5),
        Text(endpoints.$1, style: const TextStyle(fontSize: 13)),
        Container(margin: const EdgeInsets.fromLTRB(5, 4, 0, 4), width: 3, height: 14, color: color.withValues(alpha: .5)),
        Text(endpoints.$2, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        if (s.description.isNotEmpty && s.description != endpoints.$1 && s.description != endpoints.$2) ...[
          const SizedBox(height: 4),
          Text(s.description, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      ])),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final route = _selected;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFEAE9EE)), borderRadius: BorderRadius.circular(17)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.serverDemo ? '서버 시연 경로' : '이동 경로 검색 결과', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 12),
          Row(children: [const Icon(Icons.trip_origin, color: Color(0xFF4936D8), size: 19), const SizedBox(width: 9),
            Expanded(child: Text(widget.originName, style: const TextStyle(fontWeight: FontWeight.w600)))]),
          const SizedBox(height: 10),
          Row(children: [const Icon(Icons.location_on, color: Colors.redAccent, size: 19), const SizedBox(width: 9),
            Expanded(child: Text(widget.destinationName, style: const TextStyle(fontWeight: FontWeight.w600)))]),
          const Divider(height: 22),
          Wrap(spacing: 12, runSpacing: 6, children: [
            Text('기준 ${_clock(widget.referenceTime ?? DateTime.now())}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            if (widget.desiredArrival != null)
              Text('도착 희망 ${_clock(widget.desiredArrival!)}', style: const TextStyle(color: Color(0xFF4936D8), fontWeight: FontWeight.w700, fontSize: 12)),
          ]),
        ])),
      const SizedBox(height: 12),
      if (widget.loading) const LinearProgressIndicator(),
      if (widget.error != null)
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(widget.error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      if (widget.routes.isNotEmpty) ...[
        Text('추천 경로 ${widget.routes.length}개', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        for (var i = 0; i < widget.routes.length; i++) _card(widget.routes[i], i),
        if (route != null) ...[
          const SizedBox(height: 8),
          Text('선택 경로 · ${route.title}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          SizedBox(height: 285, child: RouteInlineMap(
            key: ValueKey('${route.id}-${widget.origin?.id}-${widget.destination?.id}'),
            candidate: route, origin: widget.origin, destination: widget.destination,
            routeStops: route.segments.any((s) => s.geometry.isNotEmpty) ? widget.routeStops : const [],
            nearbyPlaces: route.segments.any((s) => s.geometry.isNotEmpty) ? widget.nearbyPlaces : const [],
          )),
          const SizedBox(height: 5),
          const Text('서버에서 제공된 좌표만 지도에 표시합니다. 지도 배경에는 인터넷이 필요합니다.',
              style: TextStyle(fontSize: 11, color: Colors.black54)),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            label: Text(_expanded ? '구간 정보 접기' : '구간별 출발·도착 정보 펼치기')),
          if (_expanded) _details(route),
        ],
        PlanDetailsPanel(key: ValueKey(widget.selectedId ?? route?.id ?? 'none'),
          selectedRoute: route, plan: widget.plan, desiredArrival: widget.desiredArrival),
      ] else if (!widget.loading && widget.error == null)
        const Padding(padding: EdgeInsets.all(12), child: Text('검색된 경로가 없습니다.')),
    ]);
  }
}
