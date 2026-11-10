import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import '../models/route_candidate.dart';
import '../data/demo_route_options.dart';
import '../data/demo_route_style.dart';

/// The map never invents a line: only API-provided geometry is drawn.
class RouteInlineMap extends StatelessWidget {
  final RouteCandidate? candidate;
  final Place? origin;
  final Place? destination;
  final List<Place> routeStops;
  final List<Place> nearbyPlaces;
  final List<LatLng>? demoPath;
  final List<DemoRouteLeg>? demoLegs;
  final List<String>? demoStopNames;
  final List<LatLng>? demoStopPositions;
  const RouteInlineMap({super.key, this.candidate, this.origin, this.destination,
    this.demoPath, this.demoStopNames, this.demoStopPositions, this.demoLegs,
    this.routeStops = const [], this.nearbyPlaces = const []});

  /// Render a walking route as short grey dashed polylines without plugin-specific patterns.
  static List<Polyline> walkingDashes(List<LatLng> geometry) {
    final result = <Polyline>[];
    for (var i = 0; i + 1 < geometry.length; i++) {
      final a = geometry[i], b = geometry[i + 1];
      // ~8 m dash and ~6 m gap; approximate in metres at Seoul latitude.
      final dx = (b.longitude - a.longitude) * 88000;
      final dy = (b.latitude - a.latitude) * 111000;
      final length = (dx * dx + dy * dy);
      final meters = length == 0 ? 0.0 : _sqrt(length);
      if (meters == 0) continue;
      for (var start = 0.0; start < meters; start += 14) {
        final end = (start + 8).clamp(0.0, meters);
        final t1 = start / meters, t2 = end / meters;
        result.add(Polyline(points: [
          LatLng(a.latitude + (b.latitude - a.latitude) * t1, a.longitude + (b.longitude - a.longitude) * t1),
          LatLng(a.latitude + (b.latitude - a.latitude) * t2, a.longitude + (b.longitude - a.longitude) * t2),
        ], strokeWidth: 4, color: Colors.grey));
      }
    }
    return result;
  }
  static double _sqrt(double v) {
    if (v <= 0) return 0;
    var x = v;
    for (var i = 0; i < 15; i++) { x = (x + v / x) / 2; }
    return x;
  }

  @override
  Widget build(BuildContext context) {
    final points = <LatLng>[];
    final lines = <Polyline>[];
    for (final segment in candidate?.segments ?? <RouteSegment>[]) {
      if (segment.type == RouteSegmentType.waiting || segment.geometry.length < 2) continue;
      final geometry = segment.geometry.map((p) => LatLng(p.latitude, p.longitude)).toList();
      points.addAll(geometry);
      if (segment.type == RouteSegmentType.walking) {
        lines.addAll(walkingDashes(geometry));
        continue;
      }
      lines.add(Polyline(points: geometry, strokeWidth: 5, color: switch (segment.type) {
        RouteSegmentType.walking => Colors.grey,
        RouteSegmentType.bus => DemoRouteStyle.bus,
        RouteSegmentType.subway => DemoRouteStyle.colorFor('SUBWAY', '${segment.lineName ?? ''} ${segment.description}'),
        RouteSegmentType.waiting => Colors.grey,
      }));
    }
    if (demoLegs != null) {
      for (final leg in demoLegs!) {
        if (leg.path.length < 2) continue;
        points.addAll(leg.path);
        if (leg.mode == 'WALKING') {
          lines.addAll(walkingDashes(leg.path));
        } else {
          lines.add(Polyline(points: leg.path, strokeWidth: 5,
            color: DemoRouteStyle.colorFor(leg.mode, leg.label)));
        }
      }
    }
    // The start/end of each leg is visible at transfer points. Exact station
    // names and line colors are also shown in the expanded route details.
    final transferMarkers = <Marker>[];
    if (demoLegs != null && demoLegs!.length > 1) {
      for (var i = 1; i < demoLegs!.length; i++) {
        final leg = demoLegs![i];
        if (leg.path.isEmpty) continue;
        transferMarkers.add(Marker(
          point: leg.path.first, width: 24, height: 24,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle, color: Colors.white,
              border: Border.all(color: DemoRouteStyle.colorFor(leg.mode, leg.label), width: 3),
            ),
            child: const Icon(Icons.swap_horiz, size: 13, color: Colors.black87),
          ),
        ));
      }
    }
    // The demo line is sourced from the bundled Kakao transit sample, not invented.
    if (demoPath != null && demoPath!.length >= 2) {
      points.addAll(demoPath!);
      lines.add(Polyline(points: demoPath!, strokeWidth: 5, color: DemoRouteStyle.bus));
    }
    final markers = <Marker>[...transferMarkers];
    if (demoLegs != null && points.length >= 2 && demoStopPositions == null) {
      markers.add(Marker(point: points.first, width: 40, height: 40,
          child: const Icon(Icons.trip_origin, color: Color(0xFF4936D8), size: 24)));
      markers.add(Marker(point: points.last, width: 40, height: 40,
          child: const Icon(Icons.location_on, color: Colors.redAccent, size: 30)));
    }
    if (demoStopPositions != null && demoStopNames != null) {
      final count = demoStopPositions!.length < demoStopNames!.length
          ? demoStopPositions!.length : demoStopNames!.length;
      for (var i = 0; i < count; i++) {
        final position = demoStopPositions![i];
        final label = demoStopNames![i];
        points.add(position);
        markers.add(Marker(
          point: position, width: 130, height: 65,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(i == 0 ? Icons.trip_origin : i == count - 1
                ? Icons.flag : Icons.circle, size: 19,
                color: i == 0 ? Colors.green : i == count - 1 ? Colors.red : Colors.blue),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(5)),
              child: Text(label, textAlign: TextAlign.center, maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
            ),
          ]),
        ));
      }
    }
    // Use real stop and place coordinates from /api/demo/context, not local guesses.
    for (var i = 0; i < routeStops.length; i++) {
      final stop = routeStops[i];
      final point = LatLng(stop.latitude, stop.longitude);
      points.add(point);
      markers.add(Marker(point: point, width: 112, height: 51,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.circle, color: Color(0xFF087F8C), size: 13),
          Container(color: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(stop.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 9))),
        ])));
    }
    for (final place in nearbyPlaces) {
      final point = LatLng(place.latitude, place.longitude);
      points.add(point);
      markers.add(Marker(point: point, width: 116, height: 51,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storefront, color: Color(0xFFF59E0B), size: 18),
          Container(color: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(place.name, maxLines: 2, overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center, style: const TextStyle(fontSize: 9))),
        ])));
    }
    if (origin != null && demoPath == null) {
      final p = LatLng(origin!.latitude, origin!.longitude);
      points.add(p);
      markers.add(Marker(point: p, width: 48, height: 48, child: const Icon(Icons.location_on, color: Colors.green, size: 38)));
    }
    if (destination != null && demoPath == null) {
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
              candidate == null && origin == null ? '출발지를 선택하면 경로를 탐색합니다.' : '경로 좌표가 없어 실제 이동 경로 선은 표시하지 않습니다.',
              textAlign: TextAlign.center,
            ))),
          ),
      ]),
    );
  }
}
