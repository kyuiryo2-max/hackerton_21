import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../config/app_theme.dart';
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
    final time = '${_two(_now.hour)}:${_two(_now.minute)}';
    final String locationText;
    if (_loading) {
      locationText = '현재 위치 확인 중…';
    } else if (position != null) {
      locationText = _regionName ?? (_regionError ?? '지역명을 확인하는 중…');
    } else {
      locationText = _positionError == null ? '위치를 아직 확인하지 못했어요' : '위치 권한을 확인해 주세요';
    }
    final hasError = position == null && _positionError != null;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        const Icon(Icons.access_time_rounded, size: 17, color: AppTheme.primary),
        const SizedBox(width: 6),
        Text(time, style: const TextStyle(fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
        Container(width: 1, height: 14, margin: const EdgeInsets.symmetric(horizontal: 10), color: AppTheme.border),
        Icon(Icons.near_me_rounded, size: 16, color: hasError ? Theme.of(context).colorScheme.error : AppTheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: Tooltip(
            message: _positionError ?? (_regionName != null ? '지역 정보 © OpenStreetMap contributors' : ''),
            child: Text(locationText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    color: hasError ? Theme.of(context).colorScheme.error : AppTheme.textStrong)),
          ),
        ),
        SizedBox(
          width: 34,
          height: 34,
          child: IconButton(
            padding: EdgeInsets.zero,
            onPressed: _loading ? null : _loadLocation,
            tooltip: '현재 위치 새로고침',
            icon: _loading
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 18),
          ),
        ),
      ]),
    );
  }
}
