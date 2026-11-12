import 'package:flutter/material.dart';

import '../../config/app_theme.dart';
import '../../models/departure_overview.dart';
import '../../services/kst_time.dart';

/// 홈 맨 위: "언제 나가야 하는지"를 가장 크게 보여 주는 카드.
class DepartureHeroCard extends StatelessWidget {
  const DepartureHeroCard({
    super.key,
    required this.overview,
    required this.now,
    required this.onOpenRoutes,
    this.onAskLate,
  });

  final DepartureOverview overview;
  final DateTime now;
  final VoidCallback onOpenRoutes;
  final VoidCallback? onAskLate;

  static String hm(DateTime? t) => t == null ? '--:--' : KstTime.hm(t);

  static String countdown(Duration d) {
    final total = (d.inSeconds / 60).ceil();
    if (total <= 0) return '0분';
    final h = total ~/ 60;
    final m = total % 60;
    if (h == 0) return '$m분';
    return m == 0 ? '$h시간' : '$h시간 $m분';
  }

  ({String headline, String detail, Color tone}) _status() {
    final departure = overview.departure;
    final prep = overview.prepStart;
    final board = overview.boardAt;
    if (departure == null) {
      return (headline: '출발 시각을 계산하지 못했어요', detail: '이동 탭에서 경로를 골라 주세요', tone: Colors.white);
    }
    if (prep != null && now.isBefore(prep)) {
      return (
        headline: '준비 시작까지 ${countdown(prep.difference(now))}',
        detail: '${KstTime.hm(prep)}부터 준비하면 여유 있어요',
        tone: Colors.white,
      );
    }
    if (now.isBefore(departure)) {
      return (
        headline: '출발까지 ${countdown(departure.difference(now))}',
        detail: '지금은 준비할 시간이에요',
        tone: const Color(0xFFFFE08A),
      );
    }
    if (board != null && now.isBefore(board)) {
      return (
        headline: '지금 나가세요',
        detail: '${overview.transitLabel ?? '교통편'} 탑승까지 ${countdown(board.difference(now))}',
        tone: const Color(0xFFFFE08A),
      );
    }
    final late = now.difference(departure).inMinutes;
    if (late <= 1) {
      return (headline: '지금 나가세요', detail: '추천 출발 시각이에요', tone: const Color(0xFFFFE08A));
    }
    return (
      headline: '출발 시각이 $late분 지났어요',
      detail: '늦었다면 AI에게 물어 다시 계산해 보세요',
      tone: const Color(0xFFFFB4B4),
    );
  }

  String get _badge => switch (overview.source) {
        DepartureSource.serverDemo => '시연 · 서버 계산',
        DepartureSource.offlineDemo => '시연 · 예시 데이터',
        DepartureSource.serverPlan => '서버 계산',
        DepartureSource.selectedRoute => '선택한 경로 기준',
        DepartureSource.scheduleEstimate => '임시 추정',
      };

  @override
  Widget build(BuildContext context) {
    final status = _status();
    final departure = overview.departure;
    final arrival = overview.arriveAt ?? overview.arriveBy;
    final lateNow = departure != null && now.difference(departure).inMinutes > 1 &&
        (overview.boardAt == null || !now.isBefore(overview.boardAt!));

    return Container(
      decoration: BoxDecoration(
        gradient: AppTheme.heroGradient,
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.28),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: DefaultTextStyle(
        style: const TextStyle(color: Colors.white),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              _Pill(text: _badge),
              const Spacer(),
              const Icon(Icons.place_rounded, size: 16, color: Colors.white70),
              const SizedBox(width: 4),
              Flexible(
                child: Text(overview.destination,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white70)),
              ),
            ]),
            const SizedBox(height: 14),
            Text(overview.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, color: Colors.white70, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(hm(departure),
                    style: const TextStyle(
                        fontSize: 52, height: 1.05, fontWeight: FontWeight.w800, letterSpacing: -1.5)),
                const SizedBox(width: 8),
                const Padding(
                  padding: EdgeInsets.only(bottom: 9),
                  child: Text('에 출발',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.13),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Icon(Icons.timer_outlined, color: status.tone, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(status.headline,
                        style: TextStyle(color: status.tone, fontSize: 17, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(status.detail, style: const TextStyle(fontSize: 13, color: Colors.white70)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            _Timeline(now: now, steps: [
              _Step('준비', overview.prepStart),
              _Step('출발', departure),
              if (overview.boardAt != null) _Step('탑승', overview.boardAt),
              _Step(overview.arriveAt != null ? '도착' : '도착 목표', arrival),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              if (overview.transitLabel != null) ...[
                const Icon(Icons.directions_bus_rounded, size: 16, color: Colors.white70),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    [
                      overview.transitLabel!,
                      if (overview.boardStopName != null) '${overview.boardStopName} 탑승',
                      if (overview.totalMinutes != null) '총 ${overview.totalMinutes}분',
                    ].join(' · '),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ),
              ] else
                Expanded(
                  child: Text(
                    overview.isEstimate
                        ? '이동 35분 + 여유 10분으로 임시 계산했어요'
                        : '준비 ${overview.prepMinutes}분 포함',
                    style: const TextStyle(fontSize: 13, color: Colors.white70),
                  ),
                ),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppTheme.primaryDark,
                    minimumSize: const Size(0, 48),
                  ),
                  onPressed: onOpenRoutes,
                  icon: const Icon(Icons.map_rounded, size: 20),
                  label: Text(overview.isEstimate ? '실제 경로 찾기' : '경로·지도 보기'),
                ),
              ),
              if (lateNow && onAskLate != null) ...[
                const SizedBox(width: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white54),
                    minimumSize: const Size(0, 48),
                  ),
                  onPressed: onAskLate,
                  child: const Text('늦었어요'),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
      );
}

class _Step {
  const _Step(this.label, this.time);
  final String label;
  final DateTime? time;
}

class _Timeline extends StatelessWidget {
  const _Timeline({required this.steps, required this.now});
  final List<_Step> steps;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    // 아직 오지 않은 첫 단계가 "다음 단계"예요.
    final nextIndex = steps.indexWhere((s) => s.time == null || now.isBefore(s.time!));
    return Row(
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          Expanded(
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: Container(
                    height: 2,
                    color: i == 0 ? Colors.transparent : (nextIndex == -1 || i <= nextIndex ? Colors.white70 : Colors.white24),
                  ),
                ),
                _Dot(done: nextIndex == -1 || i < nextIndex, current: i == nextIndex),
                Expanded(
                  child: Container(
                    height: 2,
                    color: i == steps.length - 1
                        ? Colors.transparent
                        : (nextIndex == -1 || i < nextIndex ? Colors.white70 : Colors.white24),
                  ),
                ),
              ]),
              const SizedBox(height: 6),
              Text(steps[i].label,
                  style: TextStyle(
                      fontSize: 12,
                      color: i == nextIndex ? Colors.white : Colors.white70,
                      fontWeight: i == nextIndex ? FontWeight.w800 : FontWeight.w500)),
              Text(DepartureHeroCard.hm(steps[i].time),
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: i == nextIndex ? Colors.white : Colors.white70)),
            ]),
          ),
        ],
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.done, required this.current});
  final bool done;
  final bool current;

  @override
  Widget build(BuildContext context) => Container(
        width: current ? 16 : 12,
        height: current ? 16 : 12,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: done || current ? Colors.white : Colors.white24,
          border: current ? Border.all(color: const Color(0xFFFFE08A), width: 3) : null,
        ),
        child: done && !current
            ? const Icon(Icons.check, size: 9, color: AppTheme.primary)
            : null,
      );
}
