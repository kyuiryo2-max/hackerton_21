import 'package:flutter/material.dart';

import '../../config/app_theme.dart';
import '../../models/departure_overview.dart';
import '../../services/kst_time.dart';

/// 홈 "경유 판단" 화면 조각들: 판정 카드, 시간 띠, 후보 목록 한 줄.

String hm(DateTime? t) => t == null ? '--:--' : KstTime.hm(t);

/// 목적격 조사: "2115번 버스를", "지하철 6호선을"
String withObj(String word) {
  if (word.isEmpty) return word;
  final code = word.codeUnitAt(word.length - 1);
  if (code < 0xAC00 || code > 0xD7A3) return '$word을(를)';
  return (code - 0xAC00) % 28 == 0 ? '$word를' : '$word을';
}

Color stayColor(StayStatus s) => switch (s) {
      StayStatus.ok => AppTheme.ok,
      StayStatus.tight => AppTheme.warn,
      StayStatus.bad => AppTheme.danger,
    };

Color staySoft(StayStatus s) => switch (s) {
      StayStatus.ok => AppTheme.okSoft,
      StayStatus.tight => AppTheme.warnSoft,
      StayStatus.bad => AppTheme.dangerSoft,
    };

String stayWord(StayStatus s) => switch (s) {
      StayStatus.ok => '들렀다 갈 수 있어요',
      StayStatus.tight => '빠듯하지만 가능해요',
      StayStatus.bad => '이 출발로는 어려워요',
    };

// ----------------------------------------------------------------------
// 시간 띠: 이동 → (오픈 대기) → 머무름 → 이동 → 정류장 여유 → 탑승 후 이동
// ----------------------------------------------------------------------
class StayTimeStrip extends StatelessWidget {
  const StayTimeStrip({super.key, required this.eval, required this.overview, this.big = false});

  final StayEval eval;
  final DepartureOverview overview;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final e = eval;
    final board = overview.boardAt!;
    final end = overview.arriveAt ?? board;
    final stay = e.status == StayStatus.bad ? e.need : e.dwell;
    final waitAtStop = board.difference(e.reachStop).inMinutes;
    final ride = end.difference(board).inMinutes;

    final segs = <(Color?, int, bool)>[
      (AppTheme.primary, e.candidate.walkTo, false),
      if (e.waitMinutes > 0) (null, e.waitMinutes, true),
      (stayColor(e.status), stay < 0 ? 0 : stay, false),
      (AppTheme.primary, e.candidate.walkBack, false),
      if (waitAtStop > 0) (AppTheme.border, waitAtStop, false),
      if (!e.missesVehicle && ride > 0) (AppTheme.textStrong.withValues(alpha: 0.75), ride, false),
    ];
    final used = segs.fold<int>(0, (a, s) => a + s.$2);
    final total = end.difference(e.depart).inMinutes;
    final scale = (used > total ? used : total).clamp(1, 1 << 30).toInt();
    final deadline = board.difference(e.depart).inMinutes; // 이 선을 넘으면 탈 차를 놓쳐요
    final height = big ? 14.0 : 6.0;

    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      return SizedBox(
        height: height,
        child: Stack(clipBehavior: Clip.none, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(big ? 5 : 3),
            child: Container(
              color: AppTheme.background,
              child: Row(children: [
                for (final s in segs)
                  if (s.$2 > 0)
                    Container(
                      width: w * s.$2 / scale,
                      height: height,
                      decoration: BoxDecoration(
                        color: s.$3 ? AppTheme.textMuted.withValues(alpha: 0.35) : s.$1,
                        border: const Border(right: BorderSide(color: Colors.white, width: 1.5)),
                      ),
                    ),
              ]),
            ),
          ),
          if (e.missesVehicle && deadline > 0 && deadline < scale)
            Positioned(
              left: w * deadline / scale - 1,
              top: -3,
              bottom: -3,
              child: Container(width: 2, color: AppTheme.textStrong),
            ),
        ]),
      );
    });
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.eval});
  final StayEval eval;

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        ]);
    return Wrap(spacing: 12, runSpacing: 4, children: [
      item(AppTheme.primary, '도보'),
      if (eval.waitMinutes > 0) item(AppTheme.textMuted.withValues(alpha: 0.35), '오픈 대기'),
      item(stayColor(eval.status), '머무름'),
      item(AppTheme.border, '정류장 여유'),
      if (!eval.missesVehicle) item(AppTheme.textStrong.withValues(alpha: 0.75), '탑승 후 이동'),
    ]);
  }
}

// ----------------------------------------------------------------------
// 판정 카드 (화면의 주인공)
// ----------------------------------------------------------------------
class StayVerdictCard extends StatelessWidget {
  const StayVerdictCard({
    super.key,
    required this.overview,
    required this.eval,
    required this.now,
    this.best,
    this.originName,
    this.onSetDelay,
    this.onSetNeed,
    this.onPick,
  });

  final DepartureOverview overview;
  final StayEval eval;
  final StayEval? best;
  final DateTime now;
  final String? originName;
  /// 출발 시각을 추천 출발 기준 N분으로 옮기기
  final ValueChanged<int>? onSetDelay;
  final ValueChanged<int>? onSetNeed;
  final ValueChanged<StayCandidate>? onPick;

  @override
  Widget build(BuildContext context) {
    final e = eval;
    final o = overview;
    final color = stayColor(e.status);
    final approx = e.candidate.walkSplitEstimated ? '약 ' : '';
    final transit = o.transitLabel ?? '교통편';

    final String line;
    final actions = <Widget>[];

    if (e.status != StayStatus.bad) {
      final latest = e.latestDepart;
      line = latest != null && latest.isAfter(e.depart)
          ? '필요한 ${e.need}분만 쓰면 늦어도 ${hm(latest)}에 출발해도 돼요'
          : '필요한 ${e.need}분 기준, 지금 고른 시각이 출발 마지노선이에요';
    } else {
      final latest = e.latestDepart;
      if (latest == null) {
        line = '영업시간 안에 ${e.need}분을 확보하기 어려워요. 이번엔 빼는 걸 추천해요.';
      } else if (!latest.isBefore(now)) {
        line = '${hm(latest)}까지 출발하면 ${e.need}분을 확보할 수 있어요';
        final delay = o.departure == null ? null : (latest.difference(o.departure!).inSeconds / 60).floor();
        if (delay != null && onSetDelay != null) {
          actions.add(_ActionButton(label: '출발을 ${hm(latest)}로 당기기', onTap: () => onSetDelay!(delay)));
        }
        if (e.dwell >= 1 && onSetNeed != null) {
          actions.add(_ActionButton(label: '머물 시간 ${e.dwell}분으로 줄이기', onTap: () => onSetNeed!(e.dwell)));
        }
      } else {
        line = '${hm(latest)}까지 출발했어야 해요. 다음 차를 타거나 이번엔 빼는 걸 추천해요.';
        if (e.dwell >= 1 && onSetNeed != null) {
          actions.add(_ActionButton(label: '머물 시간 ${e.dwell}분으로 줄이기', onTap: () => onSetNeed!(e.dwell)));
        }
      }
    }

    final b = best;
    final showAlt = b != null &&
        b.candidate.id != e.candidate.id &&
        (b.status.index < e.status.index || b.dwell > e.dwell + 3);
    final alt = showAlt ? b : null;

    final arrival = o.arriveAt;
    final arriveBy = o.arriveBy;
    final String tail;
    if (e.missesVehicle) {
      tail = '${withObj(transit)} 놓쳐요 · 다음 차 시각은 서버 확인이 필요해요';
    } else if (arrival != null && arriveBy != null) {
      final diff = arriveBy.difference(arrival).inMinutes;
      tail = diff >= 0 ? '일정 $diff분 전 도착' : '${-diff}분 늦게 도착';
    } else {
      tail = '';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 장소 이름 + 작은 상태 표시 (가능 여부는 보조 정보)
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(e.candidate.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              if (e.candidate.shortArea.isNotEmpty)
                Text(e.candidate.shortArea, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
            ]),
          ),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 5),
            Text(stayWord(e.status), style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
          ]),
        ]),
        const SizedBox(height: 12),
        // 주인공: 머무는 시간 + 도착 시간
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: _StatBox(
                label: '머무를 수 있는 시간',
                value: e.dwell <= 0 ? '0분' : '최대 ${e.dwell}분',
                sub: e.status == StayStatus.bad
                    ? '필요 ${e.need}분 · ${e.shortBy}분 부족'
                    : '필요 ${e.need}분 · ${e.dwell - e.need}분 남음',
                tone: e.status == StayStatus.bad ? color : AppTheme.textStrong,
                background: staySoft(e.status),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatBox(
                label: '${o.destination} 도착',
                value: e.missesVehicle ? '--:--' : hm(o.arriveAt ?? o.boardAt),
                sub: e.missesVehicle ? '${withObj(transit)} 놓쳐요' : tail,
                tone: e.missesVehicle ? AppTheme.danger : AppTheme.textStrong,
                background: AppTheme.background,
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Text(line, style: const TextStyle(fontSize: 14, color: AppTheme.textMuted)),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
        if (alt != null) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            decoration: BoxDecoration(color: AppTheme.background, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              Expanded(
                child: Text('더 오래 머물 수 있는 곳: ${alt.candidate.name}, 최대 ${alt.dwell}분',
                    style: const TextStyle(fontSize: 13)),
              ),
              TextButton(onPressed: onPick == null ? null : () => onPick!(alt.candidate), child: const Text('보기')),
            ]),
          ),
        ],
        const SizedBox(height: 16),
        StayTimeStrip(eval: e, overview: o, big: true),
        const SizedBox(height: 4),
        Row(children: [
          Text('${hm(e.depart)} 출발', style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
          const Spacer(),
          Text('${hm(o.arriveAt ?? o.boardAt)} 도착', style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
        ]),
        const SizedBox(height: 6),
        _Legend(eval: e),
        const SizedBox(height: 14),

        // 단계별 시각
        _StepRow(time: hm(e.depart), title: '${originName ?? '현재 위치'} 출발',
            sub: '도보 $approx${e.candidate.walkTo}분', line: AppTheme.primary),
        _StepRow(time: hm(e.arrivePlace), title: '${e.candidate.name} 도착',
            sub: e.waitMinutes > 0 ? '${e.candidate.openAt} 오픈까지 ${e.waitMinutes}분 대기' : '바로 이용 가능',
            dot: color, line: color),
        _StepRow(
          time: '',
          title: e.status == StayStatus.bad ? '${e.need}분 머물면' : '머무르기 최대 ${e.dwell}분',
          sub: e.status == StayStatus.bad
              ? '${hm(e.leavePlace)}에 나와야 해서 ${withObj(transit)} 놓쳐요'
              : '필요 ${e.need}분, 남는 시간 ${e.dwell - e.need}분',
          dot: color,
          line: AppTheme.primary,
        ),
        _StepRow(
          time: hm(e.leavePlace),
          title: e.status == StayStatus.bad ? '경유지 출발' : '늦어도 이때 출발',
          sub: '${o.boardStopName ?? '정류장'}까지 도보 $approx${e.candidate.walkBack}분'
              '${e.closeLimited ? ' (${e.candidate.closeAt} 마감)' : ''}',
          line: AppTheme.border,
        ),
        _StepRow(
          time: hm(o.boardAt),
          title: '$transit 탑승',
          sub: e.missesVehicle ? '이 시각까지 정류장에 못 가요' : '정류장 여유 ${DepartureOverview.stopBufferMinutes}분 포함',
          late: e.missesVehicle,
          line: AppTheme.textStrong.withValues(alpha: 0.75),
        ),
        _StepRow(
          time: e.missesVehicle ? '' : hm(o.arriveAt),
          title: '${o.destination} 도착',
          sub: tail,
          late: e.missesVehicle,
          last: true,
        ),
      ]),
    );
  }
}

class _StatBox extends StatelessWidget {
  const _StatBox({
    required this.label,
    required this.value,
    required this.sub,
    required this.tone,
    required this.background,
  });

  final String label;
  final String value;
  final String sub;
  final Color tone;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -1, color: tone)),
          ),
          if (sub.isNotEmpty)
            Text(sub,
                maxLines: 2,
                style: TextStyle(fontSize: 12, color: tone == AppTheme.textStrong ? AppTheme.textMuted : tone)),
        ]),
      );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          backgroundColor: AppTheme.background,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        onPressed: onTap,
        child: Text(label),
      );
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.time,
    required this.title,
    required this.sub,
    this.dot,
    this.line,
    this.late = false,
    this.last = false,
  });

  final String time;
  final String title;
  final String sub;
  final Color? dot;
  final Color? line;
  final bool late;
  final bool last;

  // 왼쪽 시각 46 + 간격 10 + 점 칸 14
  static const double _timeWidth = 46;
  static const double _gap = 10;
  static const double _dotColumn = 14;

  @override
  Widget build(BuildContext context) {
    // IntrinsicHeight 없이 Stack으로 세로 선을 그려요.
    // 선은 이 줄의 점 아래부터 줄 끝(다음 줄 점 위)까지 끊김 없이 이어져요.
    return Stack(clipBehavior: Clip.none, children: [
      if (!last)
        Positioned(
          left: _timeWidth + _gap + _dotColumn / 2 - 1,
          top: 15,
          bottom: -5,
          width: 2,
          child: Container(color: line ?? AppTheme.border),
        ),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: _timeWidth,
          child: Text(time,
              textAlign: TextAlign.end,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: late ? AppTheme.danger : AppTheme.textStrong)),
        ),
        const SizedBox(width: _gap),
        SizedBox(
          width: _dotColumn,
          child: Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dot ?? Colors.white,
                  border: Border.all(color: dot ?? AppTheme.textMuted, width: 2),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: _gap),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: last ? 0 : 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              if (sub.isNotEmpty)
                Text(sub, style: TextStyle(fontSize: 13, color: late ? AppTheme.danger : AppTheme.textMuted)),
            ]),
          ),
        ),
      ]),
    ]);
  }
}

// ----------------------------------------------------------------------
// 경유 후보 한 줄
// ----------------------------------------------------------------------
class StayCandidateTile extends StatelessWidget {
  const StayCandidateTile({
    super.key,
    required this.index,
    required this.eval,
    required this.overview,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final StayEval eval;
  final DepartureOverview overview;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final e = eval;
    final color = stayColor(e.status);
    final bad = e.status == StayStatus.bad;
    final meta = [
      if (e.candidate.shortArea.isNotEmpty) e.candidate.shortArea,
      e.candidate.detourMinutes <= 0 ? '우회 없음' : '왕복 +${e.candidate.detourMinutes}분',
      if (e.candidate.closeAt != null) '${e.candidate.closeAt}까지 영업',
    ].join(' · ');
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? AppTheme.primary : AppTheme.border, width: selected ? 2 : 1),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Text('$index', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.candidate.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                const SizedBox(height: 8),
                StayTimeStrip(eval: e, overview: overview),
              ]),
            ),
            const SizedBox(width: 10),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(e.dwell <= 0 ? '0분' : '최대 ${e.dwell}분',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: bad ? color : AppTheme.textStrong)),
              Text(e.missesVehicle ? '탈 차 놓침' : '${hm(overview.arriveAt ?? overview.boardAt)} 도착',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: e.missesVehicle ? AppTheme.danger : AppTheme.textMuted)),
            ]),
          ]),
        ),
      ),
    );
  }
}
