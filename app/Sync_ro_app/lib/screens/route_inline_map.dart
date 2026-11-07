import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import '../models/route_candidate.dart';

/// The map never invents a line: only API-provided geometry is drawn.
class RouteInlineMap extends StatelessWidget {
  final RouteCandidate? candidate;
  final Place? origin;
  final Place? destination;
  const RouteInlineMap({super.key, this.candidate, this.origin, this.destination});

  @override
  Widget build(BuildContext context) {
    final points = <LatLng>[];
    final lines = <Polyline>[];
    for (final segment in candidate?.segments ?? <RouteSegment>[]) {
      if (segment.type == RouteSegmentType.waiting || segment.geometry.length < 2) continue;
      final geometry = segment.geometry.map((p) => LatLng(p.latitude, p.longitude)).toList();
      points.addAll(geometry);
      lines.add(Polyline(points: geometry, strokeWidth: 5, color: switch (segment.type) {
        RouteSegmentType.walking => Colors.green,
        RouteSegmentType.bus => Colors.blue,
        RouteSegmentType.subway => Colors.deepOrange,
        RouteSegmentType.waiting => Colors.grey,
      }));
    }
    final markers = <Marker>[];
    if (origin != null) {
      final p = LatLng(origin!.latitude, origin!.longitude);
      points.add(p);
      markers.add(Marker(point: p, width: 48, height: 48, child: const Icon(Icons.location_on, color: Colors.green, size: 38)));
    }
    if (destination != null) {
      final p = LatLng(destination!.latitude, destination!.longitude);
      points.add(p);
      markers.add(Marker(point: p, width: 48, height: 48, child: const Icon(Icons.location_on, color: Colors.red, size: 38)));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(children: [
        FlutterMap(
          options: MapOptions(
            initialCenter: points.isEmpty ? const LatLng(37.5665, 126.9780) : points.first,
            initialZoom: 12,
            initialCameraFit: points.length >= 2
                ? CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.all(42), maxZoom: 15)
                : null,
          ),
          children: [
            TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.syncro.sync_ro_app'),
            PolylineLayer(polylines: lines),
            MarkerLayer(markers: markers),
            const RichAttributionWidget(attributions: [TextSourceAttribution('OpenStreetMap contributors')]),
          ],
        ),
        if (lines.isEmpty)
          Positioned(
            left: 12, right: 12, top: 12,
            child: Card(child: Padding(padding: const EdgeInsets.all(10), child: Text(
              candidate == null ? '출발지를 선택하면 경로를 탐색합니다.' : '경로 좌표가 없어 지도에 경로 선을 표시할 수 없습니다.',
              textAlign: TextAlign.center,
            ))),
          ),
      ]),
    );
  }
}
