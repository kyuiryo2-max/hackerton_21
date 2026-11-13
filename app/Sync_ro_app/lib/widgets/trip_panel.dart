import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/route_candidate.dart';
import '../models/trip_progress.dart';
import '../services/kst_time.dart';
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
    this.onSkip,
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

  @override
  State<TripPanel> createState() => _TripPanelState();
}

class _TripPanelState extends State<TripPanel> {
  final _input = TextEditingController();
  String? _question;
  String? _answer;
  bool _asking = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
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
    final p = widget.plan, now = widget.now;
    final step = p.steps[widget.index];
    int left(DateTime t) => TripPlan.minutesUntil(t, now);
    final soon = p.soonMinutes(now);
    final live = soon.isEmpty ? '' : ' · 실시간 ${soon.take(2).map((m) => '$m분').join(', ')} 뒤';
    switch (step.phase) {
      case TripPhase.toPlace:
        return (
          title: '${p.placeName}까지 걷는 중',
          sub: '${KstTime.hm(p.arrivePlace)} 도착 예정 · ${KstTime.hm(p.leavePlace)}까지 머물 수 있어요',
          action: '도착했어요',
        );
      case TripPhase.atPlace:
        final m = left(p.leavePlace!);
        return (
          title: m > 0 ? '${p.placeName}에서 $m분 더 있어도 돼요' : '지금 나가야 해요',
          sub: '${KstTime.hm(p.leavePlace)}에 나오면 ${p.rideName} ${KstTime.hm(p.boardAt)} 탑승',
          action: '나왔어요',
        );
      case TripPhase.toStop:
        return (
          title: '${p.stopName}까지 걷는 중',
          sub: '${KstTime.hm(p.boardAt)} ${p.rideName} 탑승 · ${left(p.boardAt)}분 남음$live',
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
          sub: '${p.destination} ${KstTime.hm(p.arriveAt)} 도착 · ${left(p.arriveAt)}분 남음',
          action: '도착했어요',
        );
      case TripPhase.arrived:
        return (title: '${p.destination} 도착', sub: '이동 종료를 눌러 마무리해요', action: null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status();
    final progress = widget.plan.progressAt(widget.now, widget.index);
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
                decoration: const InputDecoration(
                  hintText: '예: 몇 분 남았어? · 5분 늦을 것 같아',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 6),
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
