import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_theme.dart';

/// 위치를 못 받은 이유
enum LocationIssue { serviceOff, denied, timeout, unknown }

class LocationAccessException implements Exception {
  const LocationAccessException(this.issue, this.message);
  final LocationIssue issue;
  final String message;
  @override
  String toString() => message;
}

/// 현재 위치 받기 + 권한이 막혔을 때 켜는 방법 안내.
///
/// 웹(특히 iPhone Safari)에서는 권한 상태 확인(Permissions API) 값이 실제와 다를 수 있어서,
/// 확인 없이 바로 위치를 요청해요. 그래야 브라우저의 "위치 허용" 창이 떠요.
/// 브라우저는 사용자가 버튼을 눌렀을 때 요청해야 창을 잘 띄워 줘요.
class LocationAccess {
  static const _grantedKey = 'sync_ro_location_ok_v1';

  /// 예전에 위치를 받은 적이 있으면 화면을 열자마자 바로 요청해도 돼요.
  static Future<bool> wasGranted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_grantedKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _remember(bool ok) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_grantedKey, ok);
    } catch (_) {}
  }

  static Future<Position> current() async {
    try {
      if (!kIsWeb) {
        if (!await Geolocator.isLocationServiceEnabled()) {
          throw const LocationAccessException(LocationIssue.serviceOff, '휴대폰의 위치 서비스가 꺼져 있어요');
        }
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
          throw const LocationAccessException(LocationIssue.denied, '위치 권한이 꺼져 있어요');
        }
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 15));
      await _remember(true);
      return p;
    } on LocationAccessException catch (e) {
      if (e.issue == LocationIssue.denied) await _remember(false);
      rethrow;
    } on PermissionDeniedException {
      await _remember(false);
      throw const LocationAccessException(LocationIssue.denied, '위치 권한이 꺼져 있어요');
    } on LocationServiceDisabledException {
      throw const LocationAccessException(LocationIssue.serviceOff, '휴대폰의 위치 서비스가 꺼져 있어요');
    } on TimeoutException {
      throw const LocationAccessException(LocationIssue.timeout, '위치를 찾는 데 시간이 오래 걸려요');
    } catch (e) {
      // 웹 브라우저 오류 코드 1 = 사용자가 거부 (PERMISSION_DENIED)
      final text = '$e'.toLowerCase();
      if (text.contains('denied') || text.contains('permission') || text.contains('code: 1')) {
        await _remember(false);
        throw const LocationAccessException(LocationIssue.denied, '위치 권한이 꺼져 있어요');
      }
      throw const LocationAccessException(LocationIssue.unknown, '현재 위치를 찾지 못했어요');
    }
  }

  static bool get _isIos => defaultTargetPlatform == TargetPlatform.iOS;

  /// 권한 켜는 방법 (아이폰 Safari / 안드로이드 Chrome / 설치 앱을 나눠서)
  static List<String> _steps(LocationIssue issue) {
    if (issue == LocationIssue.timeout) {
      return ['실내라면 창가로 가거나 Wi-Fi를 켜면 더 빨리 찾아요.', '그래도 안 되면 출발지를 직접 골라 주세요.'];
    }
    if (_isIos && kIsWeb) {
      return [
        if (issue == LocationIssue.serviceOff) '설정 → 개인정보 보호 및 보안 → 위치 서비스를 켜요.',
        '주소창 왼쪽 「가가」(aA) 버튼 → 웹 사이트 설정 → 위치 → 「허용」 또는 「묻기」로 바꿔요.',
        '그래도 안 뜨면: 설정 → 개인정보 보호 및 보안 → 위치 서비스 → Safari 웹 사이트 → 「앱을 사용하는 동안」으로 바꿔요.',
        '바꾼 뒤 이 페이지로 돌아와 「다시 시도」를 눌러요.',
      ];
    }
    if (_isIos) {
      return [
        if (issue == LocationIssue.serviceOff) '설정 → 개인정보 보호 및 보안 → 위치 서비스를 켜요.',
        '설정 → Sync_ro → 위치 → 「앱을 사용하는 동안」으로 바꿔요.',
        '돌아와서 「다시 시도」를 눌러요.',
      ];
    }
    if (kIsWeb) {
      return [
        if (issue == LocationIssue.serviceOff) '휴대폰 빠른 설정에서 「위치」를 켜요.',
        '주소창 왼쪽 자물쇠(또는 설정) 아이콘 → 권한 → 위치 → 「허용」으로 바꿔요.',
        '돌아와서 「다시 시도」를 눌러요.',
      ];
    }
    return [
      if (issue == LocationIssue.serviceOff) '휴대폰 빠른 설정에서 「위치」를 켜요.',
      '설정 → 애플리케이션 → Sync_ro → 권한 → 위치 → 「앱 사용 중에만 허용」으로 바꿔요.',
      '돌아와서 「다시 시도」를 눌러요.',
    ];
  }

  /// 권한이 막혔을 때 보여 주는 안내. 위치 없이도 계속 쓸 수 있게 길을 열어 둬요.
  static Future<void> showHelp(
    BuildContext context,
    LocationIssue issue, {
    VoidCallback? onRetry,
    VoidCallback? onWithoutLocation,
    String withoutLabel = '위치 없이 계속하기',
  }) {
    final steps = _steps(issue);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: AppTheme.primarySoft, borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.location_on_rounded, color: AppTheme.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  switch (issue) {
                    LocationIssue.serviceOff => '위치 서비스가 꺼져 있어요',
                    LocationIssue.denied => '위치 권한이 꺼져 있어요',
                    LocationIssue.timeout => '위치를 찾지 못했어요',
                    LocationIssue.unknown => '위치를 찾지 못했어요',
                  },
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            const Text('내 위치는 출발 시각과 경로를 계산할 때만 쓰고, 서버에 저장하지 않아요.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13)),
            const SizedBox(height: 14),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(color: AppTheme.primary, shape: BoxShape.circle),
                    child: Text('${i + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(steps[i], style: const TextStyle(height: 1.45))),
                ]),
              ),
            const SizedBox(height: 6),
            if (onRetry != null)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    Navigator.pop(sheet);
                    onRetry();
                  },
                  child: const Text('다시 시도'),
                ),
              ),
            if (onWithoutLocation != null) ...[
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(sheet);
                    onWithoutLocation();
                  },
                  child: Text(withoutLabel),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
