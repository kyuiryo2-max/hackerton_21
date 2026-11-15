import 'package:speech_to_text/speech_to_text.dart' as stt;

/// 음성 입력.
///
/// speech_to_text 는 앱 전체에서 하나만 있고, onStatus·onError 는 **처음 initialize 할 때만** 등록돼요.
/// 그래서 AI 탭이 먼저 초기화하면 이동 중 팝업의 콜백은 연결되지 않아 음성 결과를 못 받았어요 (11/14).
/// 이제 한 번만 초기화하고, 지금 쓰는 화면의 콜백으로 넘겨 줘요. 쓸 때마다 initialize 를 불러 콜백을 바꿔요.
class SpeechInputService {
  static final stt.SpeechToText _speech = stt.SpeechToText();
  static bool _available = false;
  static void Function(String)? _onStatus;
  static void Function(String)? _onError;

  bool get isListening => _speech.isListening;

  /// onError: 인식 실패 이유 (예: no-speech = 못 알아들음, not-allowed = 마이크 권한 없음)
  Future<bool> initialize({void Function(String)? onStatus, void Function(String)? onError}) async {
    _onStatus = onStatus;
    _onError = onError;
    if (!_available) {
      // 실패하면 다음에 다시 시도할 수 있게 성공했을 때만 기억해요
      _available = await _speech.initialize(
        onStatus: (status) => _onStatus?.call(status),
        onError: (error) => _onError?.call(error.errorMsg),
      );
    }
    return _available;
  }

  Future<void> listen({required void Function(String) onText}) async {
    await _speech.listen(
      onResult: (result) => onText(result.recognizedWords),
      listenOptions: stt.SpeechListenOptions(
        localeId: 'ko_KR',
        listenFor: const Duration(minutes: 2),
        pauseFor: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> stop() => _speech.stop();

  void dispose() {
    if (_speech.isListening) _speech.cancel();
    _onStatus = null;
    _onError = null;
  }
}
