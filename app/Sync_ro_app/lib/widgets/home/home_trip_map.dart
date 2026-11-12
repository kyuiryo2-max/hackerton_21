import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../config/app_theme.dart';
import '../../data/demo_route_style.dart';
import '../../models/departure_overview.dart';
import 'stay_planner_card.dart';

/// 홈 맨 위 지도: 출발지 · 경유 후보(번호 핀, 판정 색) · 도착지 · 탈 노선.
///
/// 이동 탭 지도와 같은 원칙으로, 선은 API가 준 좌표만 그려요 (경유지까지 직선을 지어내지 않아요).
class HomeTripMap extends StatelessWidget {
  const HomeTripMap({
    super.key,
    required this.overview,
    required this.evals,
    required this.selectedId,
    required this.routePath,
    required this.onPick,
    this.height = 280,
  });

  final DepartureOverview overview;
  final List<StayEval> evals;
  final String? selectedId;
  /// 탈 노선 좌표 (시연: 내장 카카오 샘플 / 실제: 고른 경로 segments)
  final List<LatLng> routePath;
  final ValueChanged<StayCandidate> onPick;
  final double height;

  static LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);

  @override
  Widget build(BuildContext context) {
    final points = <LatLng>[];
    final markers = <Marker>[];
    final origin = overview.origin;
    final dest = overview.destinationPoint;

    if (routePath.length >= 2) points.addAll(routePath);
    if (origin != null) points.add(_ll(origin));
    if (dest != null) points.add(_ll(dest));

    // 핀: 선택 안 된 것 먼저, 선택된 것을 맨 위에
    final ordered = [
      for (var i = 0; i < evals.length; i++) (i, evals[i]),
    ]..sort((a, b) => (a.$2.candidate.id == selectedId ? 1 : 0).compareTo(b.$2.candidate.id == selectedId ? 1 : 0));
    var pinned = 0;
    for (final (i, e) in ordered) {
      final p = e.candidate.point;
      if (p == null) continue;
      pinned++;
      final on = e.candidate.id == selectedId;
      points.add(_ll(p));
      markers.add(Marker(
        point: _ll(p),
        width: on ? 150 : 34,
        height: on ? 70 : 34,
        child: GestureDetector(
          onTap: () => onPick(e.candidate),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (on) _Tag(text: e.candidate.name),
            Container(
              width: on ? 28 : 24,
              height: on ? 28 : 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: stayColor(e.status),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: on
                    ? [BoxShadow(color: stayColor(e.status).withValues(alpha: 0.35), blurRadius: 0, spreadRadius: 8)]
                    : null,
              ),
              child: Text('${i + 1}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ]),
        ),
      ));
    }
    if (origin != null) {
      markers.add(Marker(
        point: _ll(origin),
        width: 150,
        height: 58,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _Tag(text: '${origin.name} 출발'),
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: AppTheme.textStrong,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
        ]),
      ));
    }
    if (dest != null) {
      markers.add(Marker(
        point: _ll(dest),
        width: 150,
        height: 58,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _Tag(text: '${dest.name} ${hm(overview.arriveBy)}', strong: true),
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: AppTheme.textStrong,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
        ]),
      ));
    }

    final cameraKey = points.isEmpty
        ? 'empty'
        : '${points.length}:${points.first.latitude}:${points.last.longitude}:$selectedId';
    final chip = overview.transitLabel == null
        ? '경로 정보 없음'
        : '${overview.transitLabel} ${hm(overview.boardAt)} 탑승 · 총 ${overview.totalMinutes ?? '-'}분';

    return SizedBox(
      height: height,
      child: Stack(children: [
        if (points.isEmpty)
          Container(color: AppTheme.primarySoft)
        else
          FlutterMap(
            key: ValueKey(cameraKey),
            options: MapOptions(
              initialCenter: points.first,
              initialZoom: 14,
              initialCameraFit: points.length >= 2
                  ? CameraFit.coordinates(
                      coordinates: points,
                      padding: const EdgeInsets.fromLTRB(48, 70, 48, 48),
                      maxZoom: 16,
                    )
                  : null,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.syncro.sync_ro_app',
              ),
              if (routePath.length >= 2)
                PolylineLayer(polylines: [
                  Polyline(
                    points: routePath,
                    strokeWidth: 5,
                    color: DemoRouteStyle.bus,
                    borderStrokeWidth: 3,
                    borderColor: Colors.white,
                  ),
                ]),
              MarkerLayer(markers: markers),
              const RichAttributionWidget(
                attributions: [TextSourceAttribution('OpenStreetMap contributors')],
              ),
            ],
          ),
        Positioned(
          left: 12,
          top: 12,
          child: _Glass(child: Text(chip, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
        ),
        if (evals.isNotEmpty && pinned == 0)
          const Positioned(
            right: 12,
            top: 48,
            child: _Glass(
              dashed: true,
              child: Text('후보 위치는 서버가 좌표를 주면 표시돼요',
                  style: TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            ),
          ),
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, this.strong = false});
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: strong ? AppTheme.textStrong : Colors.white,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: strong ? AppTheme.textStrong : AppTheme.border),
        ),
        child: Text(text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w700, color: strong ? Colors.white : AppTheme.textStrong)),
      );
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child, this.dashed = false});
  final Widget child;
  final bool dashed;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(dashed ? 8 : 999),
          border: Border.all(color: dashed ? AppTheme.textMuted : AppTheme.border),
        ),
        child: child,
      );
}
