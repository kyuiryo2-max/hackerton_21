import 'dart:async';
import 'package:flutter/material.dart';
import '../services/server_ask_service.dart';
import '../services/speech_input_service.dart';
import '../providers/todo_controller.dart';
import '../providers/active_route_controller.dart';
import '../config/api_config.dart';
import '../models/schedule.dart';
import '../services/schedule_draft_parser.dart';
import '../services/place_search_service.dart';
import '../models/place.dart';
import 'schedule_form_screen.dart';

/// AI 답변 아래 버튼 하나 (화면 이동·길찾기·할 일 보기, 11/14)
class _AnswerAction {
  const _AnswerAction(this.label, this.icon, {this.tab, this.placeName});
  final String label;
  final IconData icon;
  /// 0 홈 / 1 이동 / 2 할 일·일정
  final int? tab;
  /// 이 이름으로 장소를 찾아 길찾기
  final String? placeName;
}


class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, this.initialQuestion, this.onNavigate});

  /// 홈 "가는 길에 할 일"에서 넘어온 질문. 있으면 화면이 열리자마자 물어봐요.
  final String? initialQuestion;

  /// 답변 버튼으로 다른 화면을 열 때 (메인 화면이 질문 창을 닫고 탭을 바꾸거나 길찾기를 시작해요)
  final void Function({int? tab, Place? destination})? onNavigate;

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
      // 일정 추가: 서버가 add_schedule 을 주면 그 값, 아직 모르면(unsupported) 앱이 문장에서 대략 읽어요.
      final intent = response.result?['intent']?.toString() ??
          (response.intents.isEmpty ? null : response.intents.first['intent']?.toString());
      final draft = ScheduleDraft.fromServerResult(response.result) ??
          (response.schedule != null ? ScheduleDraft.fromScheduleMap(response.schedule!) : null) ??
          (intent == 'unsupported' || intent == null ? ScheduleDraft.parseLocal(message, DateTime.now()) : null);
      final goPlace = draft == null && (intent == 'unsupported' || intent == null) ? _destinationIn(message) : null;
      final reply = _Message(
        draft != null && !draft.fromServer
            ? '일정 추가 요청으로 보여요. 아래 내용으로 일정 입력 화면을 열어 드릴게요.'
            : goPlace != null
                ? '「$goPlace」까지 가는 길을 찾아 드릴게요. 아래 버튼을 누르면 이동 탭에서 경로를 보여 줘요.'
                : (response.needsConfirm && response.question != null ? response.question! : response.answer),
        false, todo: _shouldShowTodo(response) ? response.todo : null,
        intent: intent,
        engine: response.engine,
        schedule: draft,
        actions: response.needsConfirm ? const [] : _actionsFor(intent, response.result, goPlace),
        savedByServer: !ApiConfig.demoMode && response.todo?['id'] != null,
      );
      setState(() => _history.add(reply));
      // 들를 수 있다고 답한 할 일만 바로 목록에 넣어요 (되돌리기 가능, 11/14).
      // 시간이 부족한 들르기, "나중에 ~해야 해"(add_todo)는 자동으로 넣지 않고 버튼으로 확인받아요.
      if (reply.todo != null && intent == 'stopover_check' && response.result?['feasible'] == true) {
        await _addSuggestedTodo(reply, auto: true);
      }
      if (!mounted) return;
      // In real mode /api/ask may have already saved a new todo.
      // Refresh the visible todo list rather than showing an Add button again.
      if (!ApiConfig.demoMode && response.todo?['id'] != null) {
        await TodoScope.of(context).initialize();
        if (!mounted) return;
        // 들를 수 있다고 한 곳은 지금 이동에 바로 경유지로 더해요. 이미 적용한 곳이 있으면 같이 들러요 (11/14)
        final active = activeRouteController.active;
        if (intent == 'stopover_check' && response.result?['feasible'] != false && active != null) {
          final trip = ActiveRouteController.tripKey(active.destination, active.arrival);
          final current = activeRouteController.appliedFor(trip) ? activeRouteController.appliedTaskId : null;
          final ids = <String>{...?current?.split('+'), '${response.todo!['id']}'};
          activeRouteController.setApplied(ids.join('+'), null, trip);
        }
      }
      // A persisted server-side change can invalidate the current plan.
      // The demo account does not persist changes, so don't imply recalculation.
      if (!ApiConfig.demoMode && !response.needsConfirm &&
          (response.result?['intent'] == 'change_todo' || response.todo != null)) {
        activeRouteController.requestPlanRefresh();
      }
    } catch (error) {
      if (!mounted) return;
      final draft = ScheduleDraft.parseLocal(message, DateTime.now());
      setState(() => _history.add(draft == null
          ? _Message('서버 질문 요청 실패: $error\n시연 질문은 /api/ask 서버 응답만 사용합니다.', false)
          : _Message('서버에 연결하지 못했지만 일정 추가 요청으로 보여요. 아래 내용으로 일정 입력 화면을 열어 드릴게요.',
              false, schedule: draft)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _shouldShowTodo(ServerAskResponse response) {
    if (response.needsConfirm || response.todo == null) return false;
    // /api/ask persists generated todos for real users. Never POST them again.
    if (!ApiConfig.demoMode && response.todo?['id'] != null) return false;
    final result = response.result ?? const <String, dynamic>{};
    // 시간이 부족해도 나중에 할 일로는 남길 수 있어요. 서버가 can_add_todo=true 를 주면 버튼을 보여 줘요.
    if (result['can_add_todo'] == true) return true;
    // Prefer machine-readable server decision rather than a language heuristic.
    if (result['can_add_todo'] == false || result['feasible'] == false ||
        result['can_stop'] == false || result['status'] == '제외' ||
        result['status'] == '불가능') {
      return false;
    }
    final answer = response.answer.replaceAll(' ', '');
    return !['시간이부족', '시간부족', '다음에가', '들르기어려', '불가능합니다', '추천하지않']
        .any(answer.contains);
  }

  /// 답변에 맞는 버튼들 (11/14)
  List<_AnswerAction> _actionsFor(String? intent, Map<String, dynamic>? result, String? goPlace) {
    if (goPlace != null) {
      return [_AnswerAction('「$goPlace」 길찾기', Icons.directions_rounded, placeName: goPlace)];
    }
    switch (intent) {
      case 'stopover_check':
        if (result?['feasible'] == false) {
          return const [_AnswerAction('다른 경로 보기', Icons.alt_route_rounded, tab: 1)];
        }
        return const [_AnswerAction('경로에 넣어서 보기', Icons.route_rounded, tab: 1)];
      case 'next_vehicle':
      case 'time_left':
      case 'running_late':
      case 'change_route':
        return const [_AnswerAction('이동 탭에서 경로 보기', Icons.route_rounded, tab: 1)];
      case 'place_info':
        final places = result?['places'];
        final one = result?['place'];
        final names = <String>[
          if (places is List)
            for (final p in places.take(3)) if (p is Map && p['name'] != null) '${p['name']}',
          if ((places is! List || places.isEmpty) && one is Map && one['name'] != null) '${one['name']}',
        ];
        return [for (final n in names) _AnswerAction('$n 길찾기', Icons.directions_walk_rounded, placeName: n)];
      case 'change_todo':
        return const [_AnswerAction('할 일 보기', Icons.checklist_rounded, tab: 2)];
    }
    return const [];
  }

  /// "강남역 가는 길 알려줘", "홍대까지 어떻게 가?" → 강남역 / 홍대 (서버가 모르는 질문일 때만)
  static final _goRe = RegExp(
      r'^\s*(.+?)\s*(?:까지|으로|로|에|에서)?\s*(?:가는\s*(?:길|법|방법)|어떻게\s*가|가고\s*싶|가려면|길\s*찾|길찾기|가자|데려다)');
  static String? _destinationIn(String text) {
    final m = _goRe.firstMatch(text.trim());
    final place = m?.group(1)?.trim();
    if (place == null || place.isEmpty || place.length > 20) return null;
    if (const {'지금', '어디', '여기', '거기', '집', '학교', '회사', '거기까지'}.contains(place)) return null;
    return place;
  }

  Future<void> _runAction(_AnswerAction action) async {
    final go = widget.onNavigate;
    if (go == null) {
      Navigator.of(context).maybePop();
      return;
    }
    final name = action.placeName;
    if (name == null) {
      go(tab: action.tab);
      return;
    }
    try {
      final found = await PlaceSearchService().searchPlaces(name);
      if (!mounted) return;
      if (found.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('「$name」 장소를 찾지 못했어요. 이동 탭에서 직접 검색해 주세요.')));
        return;
      }
      go(destination: found.first);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('장소 검색 실패: $e')));
      }
    }
  }

  Future<void> _addSuggestedTodo(_Message message, {bool auto = false}) async {
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
    // 확인 창 없이 바로 넣고, 아래 알림에서 되돌릴 수 있어요 (11/14)
    final types = raw['place_types'] is List
        ? [for (final t in raw['place_types'] as List) '$t']
        : const <String>[];
    try {
      final saved = await controller.addTodo(title: title,
        minutes: (raw['stay_minutes'] as num?)?.toInt(),
        requiresTravel: types.isNotEmpty,
        placeTypes: types,
        important: raw['importance'] == '필수',
        placeName: null);
      if (!mounted) return;
      setState(() => message.added = true);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(auto ? '「$title」 할 일에 넣었어요. 이동 탭 경로에 반영돼요.' : '「$title」 할 일에 넣었어요.'),
        action: SnackBarAction(label: '되돌리기', onPressed: () async {
          await controller.deleteTodo(saved.id);
          if (mounted) setState(() => message.added = false);
        }),
      ));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('할 일 저장 실패: $error')),
        );
      }
    }
  }

  static String _when(DateTime d) {
    const w = ['월', '화', '수', '목', '금', '토', '일'];
    return '${d.month}/${d.day}(${w[d.weekday - 1]}) ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _openScheduleDraft(_Message message) async {
    final d = message.schedule;
    if (d == null || message.added) return;
    final saved = await Navigator.push<Schedule>(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          initial: Schedule(
            id: 0,
            title: d.title,
            location: d.location,
            startTime: d.start,
            endTime: d.end ?? d.start.add(const Duration(hours: 1)),
          ),
        ),
      ),
    );
    if (saved == null || !mounted) return;
    setState(() => message.added = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${saved.title}」 일정을 추가했어요. 할 일·일정 탭의 이번 주 일정에서 볼 수 있어요.')));
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
      // 쓸 때마다 불러서 이 화면의 콜백으로 바꿔요 (이동 중 팝업과 음성 인식을 같이 써요)
      _speechReady = await _speech.initialize(onStatus: _onSpeechStatus);
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
  void initState() {
    super.initState();
    final question = widget.initialQuestion?.trim();
    if (question != null && question.isNotEmpty) {
      _input.text = question;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _send();
      });
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
                          if (!m.mine && (m.todo != null || m.savedByServer)) ...[
                            const SizedBox(height: 7),
                            if (m.added || m.savedByServer)
                              const Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.check_circle_rounded, size: 16, color: Color(0xFF12A36B)),
                                SizedBox(width: 4),
                                Text('할 일에 넣었어요', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                              ])
                            else
                              OutlinedButton.icon(
                                onPressed: () => _addSuggestedTodo(m),
                                icon: const Icon(Icons.playlist_add),
                                label: const Text('할 일 목록에 추가'),
                              ),
                          ],
                          if (!m.mine && m.actions.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(spacing: 6, runSpacing: 6, children: [
                              for (final a in m.actions)
                                FilledButton.tonalIcon(
                                  onPressed: () => _runAction(a),
                                  icon: Icon(a.icon, size: 18),
                                  label: Text(a.label),
                                ),
                            ]),
                          ],
                          if (!m.mine && m.schedule != null) ...[
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF4F2FF),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text(m.schedule!.title, style: const TextStyle(fontWeight: FontWeight.w800)),
                                Text('${_when(m.schedule!.start)}${m.schedule!.timeGuessed ? ' (시각을 못 찾아 기본값)' : ''}'),
                                if (m.schedule!.location.isNotEmpty) Text('장소: ${m.schedule!.location}'),
                              ]),
                            ),
                            const SizedBox(height: 6),
                            FilledButton.icon(
                              onPressed: m.added ? null : () => _openScheduleDraft(m),
                              icon: const Icon(Icons.edit_calendar),
                              label: Text(m.added ? '일정 추가 완료' : '확인하고 일정 추가'),
                            ),
                            if (!m.schedule!.fromServer)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Text('서버 AI가 아직 일정 추가를 지원하지 않아 앱이 문장에서 대략 읽은 값이에요. 저장 전에 확인해 주세요.',
                                    style: TextStyle(fontSize: 11, color: Colors.black54)),
                              ),
                          ],
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
  final ScheduleDraft? schedule;
  /// 답변에 맞는 버튼 (경로 보기, 길찾기 …)
  final List<_AnswerAction> actions;
  /// 실제 모드: 서버가 이미 할 일로 저장했어요
  final bool savedByServer;
  bool added = false;
  _Message(this.text, this.mine,
      {this.todo, this.intent, this.engine, this.schedule, this.actions = const [], this.savedByServer = false});
}
