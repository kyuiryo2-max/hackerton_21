import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 안드로이드 홈 화면 위젯과 앱 사이의 얇은 다리.
///
/// 위젯은 Flutter 화면을 그릴 수 없어서 네이티브 AppWidgetProvider가 그리고,
/// 여기서는 '위젯 다시 그리기'와 '위젯에서 앱 열기'만 주고받아요.
class HomeWidgetBridge {
  HomeWidgetBridge._();

  static const MethodChannel _channel = MethodChannel('sync_ro/home_widget');

  /// 위젯에서 앱을 열 때 이동할 화면 번호 (3 = 메모 화면).
  static final ValueNotifier<int?> requestedTab = ValueNotifier<int?>(null);

  /// 위젯 하단 입력줄에서 '빠른 메모'를 요청했을 때 증가해요.
  static final ValueNotifier<int> quickCaptureRequested = ValueNotifier<int>(0);

  static bool _initialized = false;

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void init() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openTab' && call.arguments is int) {
        requestedTab.value = call.arguments as int;
      } else if (call.method == 'openQuickCapture') {
        quickCaptureRequested.value++;
      }
      return null;
    });
  }

  /// 앱을 새로 시작했을 때 위젯이 요청한 탭 번호를 한 번만 가져와요.
  static Future<int?> consumeLaunchTab() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<int>('consumeLaunchTab');
    } catch (_) {
      return null;
    }
  }

  /// 앱을 새로 시작했을 때 위젯이 '빠른 메모'를 요청했는지 한 번만 가져와요.
  static Future<bool> consumeQuickCapture() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('consumeQuickCapture') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 위젯에 보이는 목록을 지금 저장된 메모로 다시 그려요.
  static Future<void> refresh() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('refreshWidget');
    } catch (_) {
      // 웹·iOS이거나 홈 화면에 위젯이 없으면 조용히 넘어가요.
    }
  }

  /// 안드로이드 8.0+ 에서 '위젯 추가' 확인 창을 띄워요.
  static Future<bool> requestPinWidget() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('requestPinWidget') ?? false;
    } catch (_) {
      return false;
    }
  }
}
