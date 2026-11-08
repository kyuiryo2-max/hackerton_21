import 'package:flutter/material.dart';

/// A stop-order diagram, not a geographic route or an online map.
class OfflineRouteDiagram extends StatelessWidget {
  final List<dynamic> stops;
  const OfflineRouteDiagram({super.key, required this.stops});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFFF2F1FA), borderRadius: BorderRadius.circular(12)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Row(children: [Icon(Icons.alt_route, size: 19), SizedBox(width: 8),
        Expanded(child: Text('시연 경로 · 정류장 순서도',
          style: TextStyle(fontWeight: FontWeight.bold)))]),
      const SizedBox(height: 8),
      for (var i = 0; i < stops.length; i++)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Column(children: [
            Icon(i == 0 ? Icons.trip_origin : i == stops.length - 1
                ? Icons.flag_circle : Icons.circle_outlined, size: 18,
                color: const Color(0xFF4936D8)),
            if (i != stops.length - 1)
              Container(height: 21, width: 2, color: const Color(0xFF4936D8)),
          ]),
          const SizedBox(width: 10),
          Expanded(child: Padding(padding: const EdgeInsets.only(bottom: 12),
            child: Text('${stops[i]}', maxLines: 2))),
        ]),
      const Text('실제 지도/주행 경로가 아닌 API 예시의 정류장 순서입니다.',
        style: TextStyle(fontSize: 12, color: Colors.black54)),
    ]),
  );
}
