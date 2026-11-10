import 'package:flutter/material.dart';
import '../providers/active_route_controller.dart';
import '../models/route_candidate.dart';

class ActiveRouteSummary extends StatelessWidget {
  const ActiveRouteSummary({super.key, required this.preparationMinutes, required this.onOpenRoutes});
  final int preparationMinutes;
  final VoidCallback onOpenRoutes;
  String clock(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: activeRouteController,
    builder: (context, _) {
      final active = activeRouteController.active;
      if (active == null) return const SizedBox.shrink();
      final route = active.selected;
      final leave = active.arrival.subtract(Duration(minutes: route.totalMinutes));
      final ready = leave.subtract(Duration(minutes: preparationMinutes));
      final transit = route.segments.where((s) => s.type == RouteSegmentType.bus || s.type == RouteSegmentType.subway);
      final first = transit.isEmpty ? null : transit.first;
      final name = first == null ? '도보 이동' : '${first.lineName ?? first.description} · ${first.startName ?? '탑승 위치 미제공'}';
      return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('선택한 경로 · 준비 및 출발', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          Text('${active.origin} → ${active.destination}'),
          const SizedBox(height: 8),
          Text('준비 시작 ${clock(ready)}   ·   출발 ${clock(leave)}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text('준비 $preparationMinutes분 · 이동 ${route.totalMinutes}분 · 도착 희망 ${clock(active.arrival)}'),
          const SizedBox(height: 6),
          Text('첫 교통수단: $name'),
          const Text('도착 희망시각에서 역산한 추정값이며 실제 배차시각은 반영되지 않을 수 있어요.',
            style: TextStyle(fontSize: 11, color: Colors.black54)),
          Align(alignment: Alignment.centerRight, child: TextButton(
            onPressed: onOpenRoutes, child: const Text('이동 탭에서 경로 보기'))),
        ],
      )));
    },
  );
}
