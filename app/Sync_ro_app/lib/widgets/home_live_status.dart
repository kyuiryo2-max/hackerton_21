import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../services/approximate_location_service.dart';

/// Current device time and GPS position. No demo coordinates are substituted.
class HomeLiveStatus extends StatefulWidget {
  const HomeLiveStatus({super.key});

  @override
  State<HomeLiveStatus> createState() => _HomeLiveStatusState();
}

class _HomeLiveStatusState extends State<HomeLiveStatus> {
  DateTime _now = DateTime.now();
  Timer? _ticker;
  Position? _position;
  final ApproximateLocationService _locationService = ApproximateLocationService();
  String? _regionName;
  String? _regionError;
  String? _positionError;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadLocation();
    });
  }

  Future<void> _loadLocation() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _positionError = null;
      _regionError = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError('기기의 위치 서비스가 꺼져 있습니다.');
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('위치 권한이 필요합니다.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      setState(() {
        _position = position;
        _regionName = null;
      });
      try {
        final region = await _locationService.regionFor(
          position.latitude, position.longitude,
        );
        if (!mounted) return;
        setState(() {
          _regionName = region;
          _regionError = region == null ? '지역명을 찾지 못했어요.' : null;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _regionError = '지역명 조회에 실패했어요. 새로고침해 주세요.');
      }
    } catch (error) {
      if (mounted) setState(() => _positionError = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final position = _position;
    final time = '${_two(_now.hour)}:${_two(_now.minute)}:${_two(_now.second)}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.access_time, size: 20),
            const SizedBox(width: 9),
            Text('현재 시각', style: Theme.of(context).textTheme.bodyMedium),
            const Spacer(),
            Text(time, style: Theme.of(context).textTheme.titleMedium),
          ]),
          const Divider(height: 20),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.my_location, size: 20),
            const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('현재 위치'),
              const SizedBox(height: 4),
              if (_loading)
                const Text('현재 지역을 확인하는 중…')
              else if (position != null)
                Text(_regionName ?? (_regionError ?? '지역명을 확인하는 중…'),
                    style: Theme.of(context).textTheme.bodySmall)
              else
                Text(_positionError == null ? '위치를 아직 확인하지 못했어요.' :
                     '현재 위치를 확인할 수 없습니다. 위치 권한을 확인해 주세요.',
                     style: Theme.of(context).textTheme.bodySmall),
              if (_positionError != null)
                Text(_positionError!, style: TextStyle(fontSize: 11,
                    color: Theme.of(context).colorScheme.error)),
              if (_regionName != null)
                const Text('지역 정보 © OpenStreetMap contributors',
                    style: TextStyle(fontSize: 10, color: Colors.black54)),
            ])),
            IconButton(
              onPressed: _loading ? null : _loadLocation,
              tooltip: '현재 위치 새로고침',
              icon: _loading
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ]),
        ]),
      ),
    );
  }
}
