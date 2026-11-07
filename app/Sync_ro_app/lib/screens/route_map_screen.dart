import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/place.dart';
import '../models/route_candidate.dart';

class RouteMapScreen extends StatelessWidget {
  final String origin;
  final String destination;
  final RouteCandidate candidate;
  final Place? originPlace;
  final Place? destinationPlace;

  const RouteMapScreen({
    super.key,
    required this.origin,
    required this.destination,
    required this.candidate,
    this.originPlace,
    this.destinationPlace,
  });

  Color _segmentColor(RouteSegmentType type) {
    switch (type) {
      case RouteSegmentType.walking:
        return Colors.green;
      case RouteSegmentType.bus:
        return Colors.blue;
      case RouteSegmentType.subway:
        return Colors.deepOrange;
      case RouteSegmentType.waiting:
        return Colors.grey;
    }
  }

  IconData _segmentIcon(RouteSegmentType type) {
    switch (type) {
      case RouteSegmentType.walking:
        return Icons.directions_walk;
      case RouteSegmentType.bus:
        return Icons.directions_bus;
      case RouteSegmentType.subway:
        return Icons.train;
      case RouteSegmentType.waiting:
        return Icons.access_time;
    }
  }

  String _segmentName(RouteSegmentType type) {
    switch (type) {
      case RouteSegmentType.walking:
        return '도보';
      case RouteSegmentType.bus:
        return '버스';
      case RouteSegmentType.subway:
        return '지하철';
      case RouteSegmentType.waiting:
        return '대기';
    }
  }

  @override
  Widget build(BuildContext context) {
    final originPosition = originPlace == null
        ? null
        : LatLng(originPlace!.latitude, originPlace!.longitude);

    final destinationPosition = destinationPlace == null
        ? null
        : LatLng(destinationPlace!.latitude, destinationPlace!.longitude);

    // 백엔드 경로 좌표를 지도 선으로 변환
    final polylines = <Polyline>[];

    for (final segment in candidate.segments) {
      if (segment.type == RouteSegmentType.waiting) {
        continue;
      }

      if (segment.geometry.length < 2) {
        continue;
      }

      final points = segment.geometry.map((point) {
        return LatLng(point.latitude, point.longitude);
      }).toList();

      polylines.add(
        Polyline(
          points: points,
          color: _segmentColor(segment.type),
          strokeWidth: 5,
        ),
      );
    }

    final allPositions = <LatLng>[
      if (originPosition != null) originPosition,
      for (final segment in candidate.segments)
        for (final point in segment.geometry)
          LatLng(point.latitude, point.longitude),
      if (destinationPosition != null) destinationPosition,
    ];

    const defaultCenter = LatLng(37.5665, 126.9780);

    final initialCenter = allPositions.isNotEmpty
        ? allPositions.first
        : defaultCenter;

    final markers = <Marker>[
      if (originPosition != null)
        Marker(
          point: originPosition,
          width: 60,
          height: 60,
          child: const Icon(Icons.location_on, color: Colors.green, size: 42),
        ),
      if (destinationPosition != null)
        Marker(
          point: destinationPosition,
          width: 60,
          height: 60,
          child: const Icon(Icons.location_on, color: Colors.red, size: 42),
        ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('경로 상세 지도')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            candidate.title,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            '총 ${candidate.totalMinutes}분 · '
            '도보 ${candidate.walkingMinutes}분 · '
            '대기 ${candidate.waitingMinutes}분 · '
            '환승 ${candidate.transferCount}회',
          ),
          const SizedBox(height: 16),

          SizedBox(
            height: 350,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: initialCenter,
                  initialZoom: 13,
                  initialCameraFit: allPositions.length >= 2
                      ? CameraFit.coordinates(
                          coordinates: allPositions,
                          padding: const EdgeInsets.all(55),
                          maxZoom: 15,
                        )
                      : null,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.syncro.sync_ro_app',
                  ),

                  // 실제 경로 좌표가 있는 경우만 선 표시
                  PolylineLayer(polylines: polylines),

                  MarkerLayer(markers: markers),

                  const RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution('OpenStreetMap contributors'),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 경로 범례
          const Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _MapLegend(label: '도보', color: Colors.green),
              _MapLegend(label: '버스', color: Colors.blue),
              _MapLegend(label: '지하철', color: Colors.deepOrange),
            ],
          ),

          const SizedBox(height: 12),

          if (polylines.isEmpty)
            const Text(
              '현재 선택한 경로에는 지도 좌표 데이터가 없습니다. '
              '백엔드에서 geometry를 제공하면 경로선이 표시됩니다.',
              style: TextStyle(color: Colors.orange),
            )
          else
            const Text(
              '지도에 표시된 선은 백엔드에서 전달받은 '
              '경로 좌표를 기준으로 그려집니다.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),

          const SizedBox(height: 24),

          Text('상세 이동 경로', style: Theme.of(context).textTheme.titleLarge),

          const SizedBox(height: 12),

          ListTile(
            leading: const Icon(Icons.trip_origin, color: Colors.green),
            title: const Text('출발지'),
            subtitle: Text(origin),
          ),

          ...candidate.segments.asMap().entries.map((entry) {
            final index = entry.key;
            final segment = entry.value;

            return Card(
              child: ListTile(
                leading: Icon(
                  _segmentIcon(segment.type),
                  color: _segmentColor(segment.type),
                ),
                title: Text(
                  '${index + 1}. '
                  '${_segmentName(segment.type)} '
                  '${segment.durationMinutes}분',
                ),
                subtitle: Text(segment.description),
              ),
            );
          }),

          ListTile(
            leading: const Icon(Icons.location_on, color: Colors.red),
            title: const Text('목적지'),
            subtitle: Text(destination),
          ),

          const SizedBox(height: 20),

          FilledButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
            label: const Text('경로 추천 결과로 돌아가기'),
          ),
        ],
      ),
    );
  }
}

class _MapLegend extends StatelessWidget {
  final String label;
  final Color color;

  const _MapLegend({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 18,
          height: 5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(label),
      ],
    );
  }
}
