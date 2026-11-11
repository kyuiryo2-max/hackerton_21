import '../services/kst_time.dart';
import 'package:flutter/material.dart';
import '../models/route_candidate.dart';
import '../services/server_plan_service.dart';

/// Shared for server demonstration and user-initiated route searches.
/// No server-only details are fabricated for offline results.
class PlanDetailsPanel extends StatefulWidget {
  const PlanDetailsPanel({super.key, required this.selectedRoute, this.plan,
    this.desiredArrival});
  final RouteCandidate? selectedRoute;
  final ServerPlan? plan;
  final DateTime? desiredArrival;

  @override
  State<PlanDetailsPanel> createState() => _PlanDetailsPanelState();
}

class _PlanDetailsPanelState extends State<PlanDetailsPanel> {
  final Map<String, String> _choices = {};

  String _format(DateTime? value) {
    if (value == null) return '정보 없음';
    final d = KstTime.toKst(value);
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  String _firstTransit(RouteCandidate? route) {
    if (route == null) return '정보 없음';
    for (final leg in route.segments) {
      if (leg.type == RouteSegmentType.bus || leg.type == RouteSegmentType.subway) {
        final label = leg.lineName?.trim();
        final kind = leg.type == RouteSegmentType.bus ? '버스' : '지하철';
        final start = leg.startName?.trim();
        return '${label == null || label.isEmpty ? kind : label}${start == null || start.isEmpty ? '' : ' · $start 탑승'}';
      }
    }
    return '도보 이동';
  }

  @override
  Widget build(BuildContext context) {
    final plan = widget.plan;
    final selected = widget.selectedRoute;
    final isPrimary = selected == null || selected.isRecommended;
    final suggestedDeparture = (isPrimary ? plan?.departureAt : null) ??
        (widget.desiredArrival != null && selected != null
            ? widget.desiredArrival!.subtract(Duration(minutes: selected.totalMinutes))
            : null);
    final inferred = plan == null || plan.departureDerived || !isPrimary;
    final boardAt = isPrimary ? plan?.boardAt : null;
    final arriveAt = isPrimary ? plan?.arriveAt : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 12),
      Card(child: Padding(padding: const EdgeInsets.all(14), child:
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('출발 및 도착 안내', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('추천 출발 ${_format(suggestedDeparture)}${inferred && suggestedDeparture != null ? ' (이동시간으로 역산)' : ''}'),
          if (boardAt != null) Text('대중교통 탑승 ${_format(boardAt)}'),
          if (arriveAt != null) Text('예상 도착 ${_format(arriveAt)}'),
          if (arriveAt == null && widget.desiredArrival != null)
            Text('도착 희망 ${_format(widget.desiredArrival)} (예상 도착 미제공)'),
          const SizedBox(height: 7),
          Text('첫 이동수단: ${_firstTransit(selected)}'),
        ]))),
      if (plan != null && plan.explanation.isNotEmpty)
        Padding(padding: const EdgeInsets.all(8), child: Text(plan.explanation)),
      if (plan != null && plan.todos.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('이동 중 추천 할 일', style: Theme.of(context).textTheme.titleMedium),
        for (final todo in plan.todos)
          Card(child: Padding(padding: const EdgeInsets.all(13), child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${todo['text'] ?? '할 일'}',
                  style: const TextStyle(fontWeight: FontWeight.w700))),
                Chip(label: Text('${todo['status'] ?? '미확인'}')),
              ]),
              if ('${todo['reason'] ?? ''}'.isNotEmpty)
                Text('${todo['reason']}', style: const TextStyle(fontSize: 12)),
              if (todo['status'] == '대기' && todo['options'] is List) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 5, children: [
                  for (final option in (todo['options'] as List))
                    ChoiceChip(label: Text('$option'),
                      selected: _choices['${todo['todo_id']}'] == '$option',
                      onSelected: (_) => setState(() =>
                        _choices['${todo['todo_id']}'] = '$option')),
                ]),
                if (_choices.containsKey('${todo['todo_id']}'))
                  const Text('선택은 화면에만 반영됩니다. 서버 저장·재계산은 아직 지원하지 않습니다.',
                    style: TextStyle(fontSize: 11, color: Colors.black54)),
              ],
            ]))),
      ],
    ]);
  }
}
