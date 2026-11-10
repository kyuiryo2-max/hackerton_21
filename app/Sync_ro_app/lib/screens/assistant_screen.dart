import 'dart:async';
import 'package:flutter/material.dart';
import '../services/server_ask_service.dart';
import '../services/speech_input_service.dart';
import '../providers/todo_controller.dart';
import '../providers/active_route_controller.dart';
import '../config/api_config.dart';


class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  final _api = ServerAskService();
  final _speech = SpeechInputService();
  final List<_Message> _history = [];
  bool _loading = false;
  bool _listening = false;
  Timer? _silenceTimer;
  bool _voiceFinishing = false;
  bool _speechReady = false;
  static const _silenceDuration = Duration(seconds: 3);

  Future<void> _send() async {
    final message = _input.text.trim();
    if (message.isEmpty || _loading) return;
    setState(() {
      _history.add(_Message(message, true));
      _input.clear();
      _loading = true;
    });
    try {
      final response = await _api.ask(message);
      if (!mounted) return;
      setState(() => _history.add(_Message(
        response.needsConfirm && response.question != null ? response.question! : response.answer,
        false, todo: response.needsConfirm ? null : response.todo,
        intent: response.result?['intent']?.toString(),
        engine: response.engine,
      )));
      // A persisted server-side change can invalidate the current plan.
      // The demo account does not persist changes, so don't imply recalculation.
      if (!ApiConfig.demoMode && !response.needsConfirm &&
          (response.result?['intent'] == 'change_todo' || response.todo != null)) {
        activeRouteController.requestPlanRefresh();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _history.add(_Message('서버 질문 요청 실패: $error\n시연 질문은 /api/ask 서버 응답만 사용합니다.', false)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addSuggestedTodo(_Message message) async {
    final raw = message.todo;
    if (raw == null || message.added) return;
    final title = '${raw['text'] ?? ''}'.trim();
    if (title.isEmpty) return;
    final controller = TodoScope.of(context);
    if (controller.todos.any((item) => item.title.trim() == title && !item.isCompleted)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('같은 이름의 할 일이 이미 등록되어 있어요.')),
        );
      }
      return;
    }
    final confirmed = await showDialog<bool>(context: context, builder: (context) =>
      AlertDialog(title: const Text('할 일에 추가할까요?'),
        content: Text('「$title」를 내 할 일 목록에 추가합니다.\n'
          '서버의 경로 추천에 자동으로 반영되는 것은 아니며, 계획은 다시 조회해야 합니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('추가')),
        ]));
    if (confirmed != true || !mounted) return;
    try {
      await controller.addTodo(title: title, minutes: 10,
        requiresTravel: (raw['place_types'] is List && (raw['place_types'] as List).isNotEmpty),
        placeName: null);
      if (!mounted) return;
      setState(() => message.added = true);
      activeRouteController.requestPlanRefresh();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('앱의 할 일 목록에 추가했어요. 예상 소요시간은 기본 10분으로 설정했어요.')));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('할 일 저장 실패: $error')),
        );
      }
    }
  }

  void _onSpeechStatus(String status) {
    if (!mounted || !_listening || _voiceFinishing) return;
    // Browser speech recognition may finish on its own before the timer.
    if (status == 'done' || status == 'notListening') {
      if (_input.text.trim().isNotEmpty) {
        _silenceTimer?.cancel();
        _silenceTimer = Timer(const Duration(milliseconds: 500), _finishVoice);
      } else {
        setState(() => _listening = false);
      }
    }
  }

  void _onSpeechText(String text) {
    if (!mounted || !_listening || _voiceFinishing) return;
    setState(() => _input.text = text);
    _silenceTimer?.cancel();
    if (text.trim().isNotEmpty) {
      _silenceTimer = Timer(_silenceDuration, _finishVoice);
    }
  }

  Future<void> _finishVoice() async {
    if (_voiceFinishing || !mounted) return;
    _voiceFinishing = true;
    _silenceTimer?.cancel();
    try {
      await _speech.stop();
    } finally {
      if (mounted) {
        setState(() => _listening = false);
        if (_input.text.trim().isNotEmpty) await _send();
      }
      _voiceFinishing = false;
    }
  }

  Future<void> _toggleVoice() async {
    try {
      if (_listening) {
        await _finishVoice();
        return;
      }
      if (!_speechReady) {
        _speechReady = await _speech.initialize(onStatus: _onSpeechStatus);
      }
      if (!_speechReady) throw Exception('음성 인식이 지원되지 않거나 마이크 권한이 없습니다.');
      _input.clear();
      setState(() => _listening = true);
      await _speech.listen(onText: _onSpeechText);
    } catch (error) {
      _silenceTimer?.cancel();
      if (mounted) {
        setState(() => _listening = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('음성 입력 오류: $error')));
      }
    }
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _input.dispose();
    _speech.dispose();
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 이동 질문')),
      body: SafeArea(
        child: Column(children: [
          Expanded(child: _history.isEmpty
              ? const Center(child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('예: 오후 3시까지 광화문에 가야 하는데 감기약을 살 수 있을까?\n\n질문을 입력하거나 마이크 버튼을 누르세요.', textAlign: TextAlign.center),
                ))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _history.length,
                  itemBuilder: (context, i) {
                    final m = _history[i];
                    return Align(
                      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Card(child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          SelectableText(m.text),
                          if (!m.mine && m.todo != null) ...[
                            const SizedBox(height: 7),
                            OutlinedButton.icon(
                              onPressed: m.added ? null : () => _addSuggestedTodo(m),
                              icon: const Icon(Icons.playlist_add),
                              label: Text(m.added ? '할 일 추가 완료' : '할 일 목록에 추가'),
                            ),
                          ],
                          if (!m.mine && m.intent == 'change_route')
                            const Text('실제 경로 재탐색은 서버 경로 API 지원 후 가능합니다.',
                              style: TextStyle(fontSize: 11, color: Colors.black54)),
                          if (!m.mine && m.engine == 'rule')
                            const Text('서버 규칙 기반 응답', style: TextStyle(fontSize: 11, color: Colors.black54)),
                        ]),
                      )),
                    );
                  },
                )),
          if (_loading) const LinearProgressIndicator(),
          if (_listening)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Text('듣고 있어요. 말을 마친 뒤 약 3초간 조용하면 자동으로 전송합니다.'),
            ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              IconButton(
                tooltip: _listening ? '음성 입력 종료 및 질문 전송' : '음성 입력 시작',
                onPressed: _loading ? null : _toggleVoice,
                icon: Icon(_listening ? Icons.stop_circle : Icons.mic),
              ),
              Expanded(child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(
                  hintText: '이동이나 할 일을 질문해 보세요',
                  border: OutlineInputBorder(),
                ),
              )),
              IconButton(
                tooltip: '질문 전송',
                onPressed: _loading ? null : _send,
                icon: const Icon(Icons.send),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Message {
  final String text;
  final bool mine;
  final Map<String, dynamic>? todo;
  final String? intent;
  final String? engine;
  bool added = false;
  _Message(this.text, this.mine, {this.todo, this.intent, this.engine});
}
