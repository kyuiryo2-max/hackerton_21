import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../config/app_theme.dart';
import '../data/demo_route_style.dart';
import '../models/route_candidate.dart';
import '../screens/route_inline_map.dart';

/// 이동 탭: 후보 경로를 한 지도에 겹쳐 그리고, 경로마다 "대표 점"에 번호 핀을 꽂아 비교해요.
///
/// 대표 점 = 그 경로에서 다른 경로들과 가장 멀리 떨어진 지점 (경로가 갈라지는 곳이라 구분이 잘 돼요).
/// 선은 API가 준 좌표만 그려요.
class RouteCompareMap extends StatelessWidget {
  const RouteCompareMap({
    super.key,
    required this.routes,
    required this.selectedId,
    required this.onSelect,
    this.origin,
    this.destination,
    this.originName,
    this.destinationName,
    this.height = 300,
  });

  final List<RouteCandidate> routes;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final LatLng? origin;
  final LatLng? destination;
  final String? originName;
  final String? destinationName;
  final double height;

  static String _mode(RouteSegment s) => switch (s.type) {
        RouteSegmentType.walking => 'WALKING',
        RouteSegmentType.bus => 'BUS',
        RouteSegmentType.subway => 'SUBWAY',
        RouteSegmentType.waiting => 'WAITING',
      };

  static Color segmentColor(RouteSegment s) => s.type == RouteSegmentType.waiting
      ? DemoRouteStyle.walking
      : DemoRouteStyle.colorFor(_mode(s), '${s.lineName ?? ''} ${s.description}');

  static List<LatLng> _path(RouteCandidate r) => [
        for (final s in r.segments)
          for (final p in s.geometry) LatLng(p.latitude, p.longitude),
      ];

  // 서울 위도 기준 대략 미터 단위 제곱 거리 (비교용)
  static double _d2(LatLng a, LatLng b) {
    final dx = (a.longitude - b.longitude) * 88000;
    final dy = (a.latitude - b.latitude) * 111000;
    return dx * dx + dy * dy;
  }

  /// 경로마다 다른 경로와 가장 멀리 떨어진 점. 양끝 15%는 피해요 (출발·도착은 모두 같으니까).
  static Map<String, LatLng> representativePoints(List<RouteCandidate> routes) {
    final paths = {for (final r in routes) r.id: _path(r)};
    final result = <String, LatLng>{};
    for (final r in routes) {
      final mine = paths[r.id]!;
      if (mine.isEmpty) continue;
      final others = [
        for (final o in routes)
          if (o.id != r.id) ...paths[o.id]!,
      ];
      final from = (mine.length * 0.15).floor();
      final to = (mine.length * 0.85).ceil().clamp(from + 1, mine.length).toInt();
      var best = mine[(mine.length / 2).floor()];
      if (others.isNotEmpty) {
        var bestScore = -1.0;
        // 점이 많으면 건너뛰며 봐요
        final step = ((to - from) / 80).ceil().clamp(1, 1 << 20).toInt();
        final otherStep = (others.length / 200).ceil().clamp(1, 1 << 20).toInt();
        for (var i = from; i < to; i += step) {
          var nearest = double.infinity;
          for (var j = 0; j < others.length; j += otherStep) {
            final d = _d2(mine[i], others[j]);
            if (d < nearest) nearest = d;
          }
          if (nearest > bestScore) {
            bestScore = nearest;
            best = mine[i];
          }
        }
      }
      result[r.id] = best;
    }
    return result;
  }

  /// 환승 지점: 탈것 구간이 끝나고 다음 탈것 구간이 시작되는 곳.
  static List<(LatLng, int?)> transferPoints(RouteCandidate r) {
    final out = <(LatLng, int?)>[];
    var seenRide = false;
    int? wait;
    for (final s in r.segments) {
      final ride = s.type == RouteSegmentType.bus || s.type == RouteSegmentType.subway;
      if (s.type == RouteSegmentType.waiting) wait = s.durationMinutes;
      if (ride) {
        if (seenRide && s.geometry.isNotEmpty) {
          out.add((LatLng(s.geometry.first.latitude, s.geometry.first.longitude), wait));
        }
        seenRide = true;
        wait = null;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final reps = representativePoints(routes);
    final points = <LatLng>[];
    final lines = <Polyline>[];
    final markers = <Marker>[];

    // 선택 안 된 경로: 옅은 회색
    RouteCandidate? selected;
    for (final r in routes) {
      final path = _path(r);
      points.addAll(path);
      if (r.id == selectedId) {
        selected = r;
        continue;
      }
      for (final s in r.segments) {
        if (s.geometry.length < 2) continue;
        lines.add(Polyline(
          points: [for (final p in s.geometry) LatLng(p.latitude, p.longitude)],
          strokeWidth: 4,
          color: AppTheme.textMuted.withValues(alpha: 0.45),
        ));
      }
    }
    // 선택된 경로: 노선 색 + 흰 테두리, 도보는 점선
    if (selected != null) {
      for (final s in selected.segments) {
        if (s.geometry.length < 2) continue;
        final geo = [for (final p in s.geometry) LatLng(p.latitude, p.longitude)];
        if (s.type == RouteSegmentType.walking) {
          lines.addAll(RouteInlineMap.walkingDashes(geo));
        } else {
          lines.add(Polyline(
            points: geo,
            strokeWidth: 6,
            color: segmentColor(s),
            borderStrokeWidth: 3,
            borderColor: Colors.white,
          ));
        }
      }
      for (final (p, wait) in transferPoints(selected)) {
        markers.add(Marker(
          point: p,
          width: 110,
          height: 28,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: AppTheme.textStrong),
              ),
              child: Text(wait == null ? '환승' : '환승 · 대기 $wait분',
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
            ),
          ),
        ));
      }
    }

    if (origin != null) {
      points.add(origin!);
      markers.add(_endMarker(origin!, '${originName ?? '출발'} 출발', square: false));
    }
    if (destination != null) {
      points.add(destination!);
      markers.add(_endMarker(destination!, destinationName ?? '도착', square: true));
    }

    // 번호 핀: 선택된 것을 맨 위에
    final order = [for (var i = 0; i < routes.length; i++) i]
      ..sort((a, b) => (routes[a].id == selectedId ? 1 : 0).compareTo(routes[b].id == selectedId ? 1 : 0));
    for (final i in order) {
      final r = routes[i];
      final p = reps[r.id];
      if (p == null) continue;
      final on = r.id == selectedId;
      markers.add(Marker(
        point: p,
        width: 90,
        height: on ? 64 : 34,
        child: GestureDetector(
          onTap: () => onSelect(r.id),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (on)
              Container(
                margin: const EdgeInsets.only(bottom: 3),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(color: AppTheme.textStrong, borderRadius: BorderRadius.circular(7)),
                child: Text('${r.totalMinutes}분',
                    style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
              ),
            Container(
              width: on ? 30 : 26,
              height: on ? 30 : 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? AppTheme.primary : Colors.white,
                shape: BoxShape.circle,
                border: Border.all(color: on ? Colors.white : AppTheme.primary, width: on ? 3 : 2),
                boxShadow: on
                    ? [BoxShadow(color: AppTheme.primary.withValues(alpha: 0.3), spreadRadius: 6)]
                    : const [BoxShadow(color: Color(0x22000000), blurRadius: 4)],
              ),
              child: Text('${i + 1}',
                  style: TextStyle(
                      color: on ? Colors.white : AppTheme.primary, fontSize: 13, fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      ));
    }

    final cameraKey = points.isEmpty
        ? 'empty'
        : '${routes.map((r) => r.id).join(',')}:${points.length}:${points.first.latitude}';

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          if (points.isEmpty)
            Container(
              color: AppTheme.primarySoft,
              alignment: Alignment.center,
              child: const Text('경로 좌표가 없어 지도를 그릴 수 없어요', style: TextStyle(color: AppTheme.textMuted)),
            )
          else
            FlutterMap(
              key: ValueKey(cameraKey),
              options: MapOptions(
                initialCenter: points.first,
                initialZoom: 13,
                initialCameraFit: points.length >= 2
                    ? CameraFit.coordinates(
                        coordinates: points,
                        padding: const EdgeInsets.fromLTRB(40, 56, 40, 40),
                        maxZoom: 16,
                      )
                    : null,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.syncro.sync_ro_app',
                ),
                PolylineLayer(polylines: lines),
                MarkerLayer(markers: markers),
                const RichAttributionWidget(
                  attributions: [TextSourceAttribution('OpenStreetMap contributors')],
                ),
              ],
            ),
          Positioned(
            left: 12,
            top: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppTheme.border),
              ),
              child: Text('경로 ${routes.length}개 비교 · 번호를 눌러 선택',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            ),
          ),
        ]),
      ),
    );
  }

  static Marker _endMarker(LatLng p, String label, {required bool square}) => Marker(
        point: p,
        width: 140,
        height: 56,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            margin: const EdgeInsets.only(bottom: 3),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: square ? AppTheme.textStrong : Colors.white,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: square ? AppTheme.textStrong : AppTheme.border),
            ),
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w700, color: square ? Colors.white : AppTheme.textStrong)),
          ),
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: AppTheme.textStrong,
              shape: square ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: square ? BorderRadius.circular(4) : null,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
        ]),
      );
}

/// 경로 한 줄 시간 띠: 도보(회색) · 대기(빗금 대신 옅은 회색) · 탈것(노선 색)
class RouteTimeStrip extends StatelessWidget {
  const RouteTimeStrip({super.key, required this.route, this.height = 8});
  final RouteCandidate route;
  final double height;

  @override
  Widget build(BuildContext context) {
    final segs = route.segments.where((s) => s.durationMinutes > 0).toList();
    final sum = segs.fold<int>(0, (a, s) => a + s.durationMinutes);
    // 카카오 총 시간에는 출발·도착 도보가 따로 들어 있어요. 구간 합보다 크면 남는 부분을 "기타 도보"로 그려요.
    final rest = route.totalMinutes - sum;
    final total = (sum + (rest > 0 ? rest : 0)).clamp(1, 1 << 20).toInt();
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return ClipRRect(
        borderRadius: BorderRadius.circular(height / 2),
        child: SizedBox(
          height: height,
          child: Row(children: [
            for (final s in segs)
              Container(
                width: w * s.durationMinutes / total,
                decoration: BoxDecoration(
                  color: s.type == RouteSegmentType.waiting
                      ? AppTheme.textMuted.withValues(alpha: 0.25)
                      : s.type == RouteSegmentType.walking
                          ? AppTheme.textMuted.withValues(alpha: 0.55)
                          : RouteCompareMap.segmentColor(s),
                  border: const Border(right: BorderSide(color: Colors.white, width: 1.5)),
                ),
              ),
            if (rest > 0)
              Container(width: w * rest / total, color: AppTheme.textMuted.withValues(alpha: 0.3)),
          ]),
        ),
      );
    });
  }
}
