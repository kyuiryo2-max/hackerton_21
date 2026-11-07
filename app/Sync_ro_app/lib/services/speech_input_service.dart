import 'package:speech_to_text/speech_to_text.dart' as stt;

class SpeechInputService {
  final stt.SpeechToText _speech = stt.SpeechToText();

  bool get isListening => _speech.isListening;

  Future<bool> initialize({void Function(String)? onStatus}) =>
      _speech.initialize(onStatus: onStatus);

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
    _speech.cancel();
  }
}
