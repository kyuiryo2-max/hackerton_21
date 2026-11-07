class AssistantConfig {
  // Chrome on the same PC: http://127.0.0.1:8000
  // Android emulator: http://10.0.2.2:8000 (server must bind 0.0.0.0)
  static const String baseUrl = String.fromEnvironment(
    'ASSISTANT_BASE_URL', defaultValue: 'http://127.0.0.1:8000');
}
