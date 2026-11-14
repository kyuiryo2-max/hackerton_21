import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'kst_time.dart';

/// 일정 준비 시각에 휴대폰 알림을 보내요 (안드로이드·iOS 앱만).
/// 웹(QR로 연 화면)에서는 휴대폰 알림을 못 보내서, 홈 화면 안의 안내 창만 떠요.
class PrepNotificationService {
  PrepNotificationService._();
  static final PrepNotificationService instance = PrepNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _asked = false;

  /// 알림을 눌러 앱을 열면 그 일정 id가 들어와요. 홈이 보고 "경로 따라가기" 창을 띄워요.
  final ValueNotifier<int?> tapped = ValueNotifier<int?>(null);

  bool get supported =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> init() async {
    if (!supported || _ready) return;
    try {
      tzdata.initializeTimeZones();
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      );
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (r) => tapped.value = int.tryParse(r.payload ?? ''),
      );
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        tapped.value = int.tryParse(launch?.notificationResponse?.payload ?? '');
      }
      _ready = true;
    } catch (e) {
      debugPrint('알림 준비 실패: $e');
    }
  }

  /// 처음 한 번만 알림 권한을 물어봐요.
  Future<void> askPermissionOnce() async {
    if (!_ready || _asked) return;
    _asked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (e) {
      debugPrint('알림 권한 요청 실패: $e');
    }
  }

  /// [at]에 "일정 준비할 시간이에요" 알림. 같은 일정은 새 시각으로 바꿔 다시 걸어요.
  Future<void> schedulePrep({
    required int scheduleId,
    required String title,
    required DateTime at,
    required DateTime departure,
  }) async {
    if (!_ready || scheduleId <= 0) return;
    try {
      await _plugin.cancel(scheduleId);
      if (!at.isAfter(DateTime.now())) return;
      await _plugin.zonedSchedule(
        scheduleId,
        '일정 준비할 시간이에요',
        '「$title」 ${KstTime.hm(departure)}에 나가야 해요. 눌러서 추천 경로를 따라가세요.',
        tz.TZDateTime.from(at.toUtc(), tz.UTC),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'sync_ro_prep',
            '일정 준비 알림',
            channelDescription: '일정 준비를 시작할 시각에 알려 줘요',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: '$scheduleId',
      );
    } catch (e) {
      debugPrint('알림 예약 실패: $e');
    }
  }

  /// 바로 보내는 알림 (이동 중 경로 이탈 등, 11/14)
  Future<void> showNow({required int id, required String title, required String body}) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'sync_ro_trip',
            '이동 안내',
            channelDescription: '이동 중 경로를 벗어나면 알려 줘요',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (e) {
      debugPrint('알림 실패: $e');
    }
  }

  Future<void> cancel(int scheduleId) async {
    if (!_ready || scheduleId <= 0) return;
    try {
      await _plugin.cancel(scheduleId);
    } catch (_) {}
  }
}
