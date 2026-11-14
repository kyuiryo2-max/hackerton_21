import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/route_candidate.dart';
import '../models/trip_progress.dart';
import '../services/kst_time.dart';
import '../services/speech_input_service.dart';
import 'route_compare_map.dart';

/// 이동 중 팝업 (11/13): 지도 위에 지금 단계, 진행 막대, 다음 단계 버튼, AI 질문 칸을 보여 줘요.
/// 지금 단계는 시간이 흐르는 기준이고, 계획과 다르면 버튼으로 넘겨요.
class TripPanel extends StatefulWidget {
  const TripPanel({
    super.key,
    required this.plan,
    required this.now,
    required this.index,
    required this.stripRoute,
    required this.onAdvance,
    required this.onAsk,
    required this.onEnd,
    this.onSkip,
    this.stepNow,
  });

  final TripPlan plan;
  /// 이동 중 시계 (시연 모드는 시연 시각에서 흘러가요)
  final DateTime now;
  /// 지금 단계 번호 (plan.steps)
  final int index;
  /// 진행 막대에 쓸 경로 (경유 구간이 들어간 경로)
  final RouteCandidate stripRoute;
  final VoidCallback onAdvance;
  /// 질문 → 답변 문장
  final Future<String> Function(String text) onAsk;
  /// 시연 모드: 시간 빨리 보내기 (분)
  final ValueChanged<int>? onSkip;
  /// 이동 종료 (#51 피드백 4: 팝업 안에서도 끝낼 수 있게)
  final VoidCallback onEnd;
  /// 지금 단계를 계획보다 일찍 넘겼을 때의 진행 시계 (11/14). 예: 17:21 탈 버스를 16:05에 "탔어요" →
  /// 16:05부터 버스를 탄 것으로 보고 남은 시간·도착 시각을 그만큼 앞당겨 보여 줘요
  final DateTime? stepNow;

  @override
  State<TripPanel> createState() => _TripPanelState();
}

class _TripPanelState extends State<TripPanel> {
  final _input = TextEditingController();
  String? _question;
  String? _answer;
  bool _asking = false;

  // 음성 질문 (#51 피드백 5): 말이 3초쯤 멈추면 그대로 물어봐요. AI 탭과 같은 방식이에요
  final _speech = SpeechInputService();
  bool _listening = false;
  Timer? _silence;

  @override
  void dispose() {
    _silence?.cancel();
    _speech.dispose();
    _input.dispose();
    super.dispose();
  }

  /// 브라우저가 "듣는 중"이라고 알려 준 뒤인지. 시작하자마자 오는 "안 듣는 중" 신호에 바로 끝나지 않게 해요
  bool _heard = false;

  void _onStatus(String status) {
    if (!mounted || !_listening) return;
    if (status == 'listening') {
      _heard = true;
      return;
    }
    if ((status == 'done' || status == 'notListening') && _heard) {
      if (_input.text.trim().isNotEmpty) {
        _silence?.cancel();
        _silence = Timer(const Duration(milliseconds: 500), _finishVoice);
      } else {
        setState(() => _listening = false);
        _say('잘 못 들었어요. 마이크를 누르고 다시 말해 주세요.');
      }
    }
  }

  void _onError(String error) {
    if (!mounted || error == 'aborted' || error == 'error_aborted') return; // 우리가 멈춘 것
    if (!_listening) return;
    _silence?.cancel();
    setState(() => _listening = false);
    _say(switch (error) {
      'error_no_match' || 'error_speech_timeout' || 'no-speech' => '잘 못 들었어요. 마이크를 누르고 다시 말해 주세요.',
      'not-allowed' || 'error_permission' || 'service-not-allowed' =>
        '마이크 권한이 꺼져 있어요. 주소창 왼쪽 아이콘에서 마이크를 허용해 주세요.',
      'network' || 'error_network' => '음성 인식에 인터넷 연결이 필요해요. 연결을 확인해 주세요.',
      _ => '음성 인식 오류 ($error). 글자로 입력해 주세요.',
    });
  }

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _toggleVoice() async {
    if (_listening) return _finishVoice();
    try {
      // 쓸 때마다 불러서 이 팝업의 콜백으로 바꿔요 (초기화는 앱에서 한 번만 돼요)
      final ready = await _speech.initialize(onStatus: _onStatus, onError: _onError);
      if (!ready) throw Exception('이 브라우저는 음성 인식을 지원하지 않거나 마이크 권한이 없어요 (크롬 권장)');
      _input.clear();
      _heard = false;
      setState(() => _listening = true);
      await _speech.listen(onText: (text) {
        if (!mounted || !_listening) return;
        _heard = true;
        setState(() => _input.text = text);
        _silence?.cancel();
        if (text.trim().isNotEmpty) _silence = Timer(const Duration(seconds: 2), _finishVoice);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _listening = false);
      _say('음성 입력 오류: $e');
    }
  }

  Future<void> _finishVoice() async {
    if (!_listening) return;
    _silence?.cancel();
    setState(() => _listening = false);
    await _speech.stop();
    if (mounted && _input.text.trim().isNotEmpty) await _send();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _asking) return;
    setState(() {
      _asking = true;
      _question = text;
      _answer = null;
    });
    _input.clear();
    String answer;
    try {
      answer = await widget.onAsk(text);
    } catch (e) {
      answer = '답을 받지 못했어요. 잠시 뒤 다시 물어봐 주세요.';
    }
    if (!mounted) return;
    setState(() {
      _asking = false;
      _answer = answer;
    });
  }
  ({String title, String sub, String? action}) _status() {
    final p = widget.plan;
    final now = widget.stepNow ?? widget.now;
    // 일찍 넘긴 만큼 앞으로의 계획 시각을 당겨서 보여 줘요
    final early = now.difference(widget.now);
    String hm(DateTime? t) => KstTime.hm(t?.subtract(early));
    final step = p.steps[widget.index];
    int left(DateTime t) => TripPlan.minutesUntil(t, now);
    final soon = p.soonMinutes(widget.now); // 실시간 도착은 진짜 지금 기준
    final live = soon.isEmpty ? '' : ' · 실시간 ${soon.take(2).map((m) => '$m분').join(', ')} 뒤';
    // 이동 시작을 일찍 눌렀으면 출발 시각까지 기다리라고 알려 줘요 (11/14 실제 모드)
    if (widget.index == 0 && p.beforeDepart(now) && left(p.depart) >= 1) {
      return (
        title: '${hm(p.depart)}에 출발하면 돼요',
        sub: '아직 ${left(p.depart)}분 여유 · ${p.hasStop ? '${p.placeName} 들러서 ' : ''}${p.rideName} ${hm(p.boardAt)} 탑승',
        action: '지금 출발했어요',
      );
    }
    switch (step.phase) {
      case TripPhase.toPlace:
        return (
          title: '${p.placeName}까지 걷는 중',
          sub: '${hm(p.arrivePlace)} 도착 예정 · ${hm(p.leavePlace)}까지 머물 수 있어요',
          action: '도착했어요',
        );
      case TripPhase.atPlace:
        final m = left(p.leavePlace!);
        return (
          title: m > 0 ? '${p.placeName}에서 $m분 더 있어도 돼요' : '지금 나가야 해요',
          sub: '${hm(p.leavePlace)}에 나오면 ${p.rideName} ${hm(p.boardAt)} 탑승',
          action: '나왔어요',
        );
      case TripPhase.toStop:
        return (
          title: '${p.stopName}까지 걷는 중',
          sub: '${hm(p.boardAt)} ${p.rideName} 탑승 · ${left(p.boardAt)}분 남음$live',
          action: '정류장 도착',
        );
      case TripPhase.waiting:
        return (
          title: '${p.rideName} ${left(p.boardAt)}분 뒤 탑승',
          sub: '${p.stopName}에서 기다리는 중$live',
          action: '탔어요',
        );
      case TripPhase.riding:
        return (
          title: '${p.rideName} 타는 중',
          sub: '${p.destination} ${hm(p.arriveAt)} 도착 · ${left(p.arriveAt)}분 남음',
          action: '도착했어요',
        );
      case TripPhase.arrived:
        return (title: '${p.destination} 도착', sub: '잠시 뒤 이동을 자동으로 마쳐요', action: null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status();
    final progress = widget.plan.progressAt(widget.stepNow ?? widget.now, widget.index);
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(18),
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: AppTheme.primary, borderRadius: BorderRadius.circular(20)),
              child: const Text('이동 중', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            Text('${KstTime.hm(widget.now)} 기준',
                style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            const Spacer(),
            if (widget.onSkip != null)
              TextButton.icon(
                onPressed: () => widget.onSkip!(1),
                icon: const Icon(Icons.fast_forward_rounded, size: 16),
                label: const Text('1분 뒤'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            TextButton.icon(
              onPressed: widget.onEnd,
              icon: const Icon(Icons.stop_circle_outlined, size: 16),
              label: const Text('이동 종료'),
              style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact, foregroundColor: AppTheme.danger),
            ),
          ]),
          const SizedBox(height: 6),
          Text(s.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(s.sub, style: const TextStyle(fontSize: 12.5, color: AppTheme.textMuted)),
          const SizedBox(height: 10),
          // 진행 막대: 경로 구간 띠 위에 지금 위치를 세로선으로
          LayoutBuilder(builder: (context, c) {
            final x = (c.maxWidth * progress).clamp(0.0, c.maxWidth - 2);
            return SizedBox(
              height: 14,
              child: Stack(clipBehavior: Clip.none, children: [
                Positioned(left: 0, right: 0, top: 3, child: RouteTimeStrip(route: widget.stripRoute)),
                Positioned(
                  left: x,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 3, decoration: BoxDecoration(
                      color: AppTheme.primary, borderRadius: BorderRadius.circular(2))),
                ),
              ]),
            );
          }),
          const SizedBox(height: 4),
          Row(children: [
            Text('${KstTime.hm(widget.plan.depart)} 출발', style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
            const Spacer(),
            Text('${KstTime.hm(widget.plan.arriveAt)} 도착', style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          ]),
          if (s.action != null) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(onPressed: widget.onAdvance, child: Text(s.action!)),
            ),
          ],
          if (_question != null) ...[
            const SizedBox(height: 10),
            Text('나: $_question', style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            const SizedBox(height: 2),
            Text(_asking ? '계산하는 중…' : (_answer ?? ''),
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppTheme.primary)),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                enabled: !_asking,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: _listening ? '듣고 있어요… 말이 끝나면 바로 물어봐요' : '예: 몇 분 남았어? · 5분 늦을 것 같아',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              onPressed: _asking ? null : _toggleVoice,
              icon: Icon(_listening ? Icons.stop_circle : Icons.mic, size: 20,
                  color: _listening ? AppTheme.danger : null),
              tooltip: _listening ? '말하기 끝내고 묻기' : '말로 묻기',
            ),
            IconButton.filled(
              onPressed: _asking ? null : _send,
              icon: const Icon(Icons.auto_awesome, size: 18),
              tooltip: 'AI에게 묻기',
            ),
          ]),
        ]),
      ),
    );
  }
}
