import 'dart:async';
import 'package:flutter/material.dart';
import '../models/assistant_analysis.dart';
import '../services/assistant_api_service.dart';
import '../services/speech_input_service.dart';

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _input = TextEditingController();
  final _api = AssistantApiService();
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
      final analysis = await _api.analyze(message);
      if (!mounted) return;
      setState(() => _history.add(_Message(_format(analysis), false)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _history.add(_Message('분석 실패: $error\n서버 주소와 실행 상태를 확인해 주세요.', false)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _format(AssistantAnalysis a) {
    final lines = <String>[
      '질문 분석 결과 (${a.provider})',
      '의도: ${a.intent}',
      '목적지: ${a.destination ?? '미확인'}',
      '도착 희망 시간: ${a.arrivalTime ?? '미확인'}',
      '할 일: ${a.todoDescription ?? '미확인'}',
      '장소 유형: ${a.placeCategory ?? '미확인'}',
      '예상 체류시간: ${a.estimatedMinutes == null ? '미정' : '${a.estimatedMinutes}분'}',
    ];
    if (a.needsClarification && a.clarificationQuestion != null) {
      lines.add('추가 확인: ${a.clarificationQuestion}');
    }
    lines.add('※ 아직 실제 장소 검색·경로 계산은 수행하지 않았습니다.');
    return lines.join('\n');
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
                        child: SelectableText(m.text),
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
  _Message(this.text, this.mine);
}
