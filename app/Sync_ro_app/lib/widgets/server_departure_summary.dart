import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../services/server_plan_service.dart';
import '../providers/active_route_controller.dart';

/// Home-only summary. Full route map, route comparison and todo decisions
/// belong to the Navigation tab.
class ServerDepartureSummary extends StatefulWidget {
  const ServerDepartureSummary({
    super.key,
    required this.onOpenRoutes,
    this.preparationMinutes,
  });

  final VoidCallback onOpenRoutes;
  /// Optional user-configured preparation time. The server schedule wins when
  /// present, so demo plans are not mixed with an unrelated local schedule.
  final int? preparationMinutes;

  @override
  State<ServerDepartureSummary> createState() => _ServerDepartureSummaryState();
}

class _ServerDepartureSummaryState extends State<ServerDepartureSummary> {
  final ServerPlanService _service = ServerPlanService();
  ServerPlan? _plan;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    activeRouteController.addListener(_onPlanChanged);
    _load();
  }

  int _lastRevision = activeRouteController.revision;
  void _onPlanChanged() {
    if (_lastRevision == activeRouteController.revision) return;
    _lastRevision = activeRouteController.revision;
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _service.fetch();
      if (mounted) setState(() => _plan = result);
    } catch (_) {
      if (mounted) {
        setState(() {
          _plan = null;
          _error = '서버 계획을 불러오지 못했어요. 새로고침 후 다시 시도해 주세요.';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  int? _preparationMinutes(ServerPlan plan) {
    final schedule = _asMap(plan.data['schedule']);
    final serverMinutes = schedule['prep_minutes'];
    if (serverMinutes is num && serverMinutes >= 0) return serverMinutes.toInt();
    if (widget.preparationMinutes != null && widget.preparationMinutes! >= 0) {
      return widget.preparationMinutes;
    }
    return null;
  }

  String _firstTransit(ServerPlan plan) {
    if (plan.routes.isEmpty) return '탑승 교통수단 정보 없음';
    final route = plan.routes.first;
    final legs = route['segments'] ?? route['steps'];
    Map<String, dynamic> first = route;
    if (legs is List) {
      for (final raw in legs) {
        final leg = _asMap(raw);
        final mode = '${leg['type'] ?? leg['mode'] ?? ''}'.toUpperCase();
        if (mode.contains('WALK') || mode.contains('WAIT')) continue;
        if (mode.contains('BUS') || mode.contains('SUBWAY') ||
            mode.contains('METRO') || mode.contains('TRAIN')) {
          first = leg;
          break;
        }
      }
    }
    final kind = '${first['type'] ?? first['mode'] ?? route['type'] ?? ''}'.toUpperCase();
    final name = '${first['line_name'] ?? first['name'] ?? route['name'] ?? ''}'.trim();
    final stops = first['stops'] is List ? first['stops'] as List :
        route['stops'] is List ? route['stops'] as List : const [];
    final start = '${first['start_name'] ?? first['origin_name'] ??
        (stops.isNotEmpty ? stops.first : '')}'.trim();
    final isMetro = kind.contains('SUBWAY') || kind.contains('METRO') || kind.contains('TRAIN');
    final isBus = kind.contains('BUS');
    final transport = isMetro
        ? (name.isEmpty ? '지하철' : '지하철 $name')
        : isBus
            ? (name.isEmpty ? '버스' : name.endsWith('번') ? '$name 버스' : '$name번 버스')
            : (name.isEmpty ? '대중교통' : name);
    return start.isEmpty ? transport : '$transport · $start 탑승';
  }

  String _format(DateTime? value) {
    if (value == null) return '정보 없음';
    final local = value.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    activeRouteController.removeListener(_onPlanChanged);
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final minutes = plan == null ? null : _preparationMinutes(plan);
    final departure = plan?.departureAt;
    final readyAt = minutes == null || departure == null
        ? null : departure.subtract(Duration(minutes: minutes));
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Expanded(child: Text('오늘의 준비 · 출발',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              if (ApiConfig.demoMode)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text('서버 시연', style: TextStyle(fontSize: 12)),
                ),
              IconButton(
                tooltip: '준비 및 출발 안내 새로고침',
                icon: const Icon(Icons.refresh),
                onPressed: _loading ? null : _load,
              ),
            ]),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(_error!, style: TextStyle(color: scheme.error)),
            if (plan != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _TimeItem('준비 시작', _format(readyAt),
                    emphasis: true)),
                const SizedBox(width: 12),
                Expanded(child: _TimeItem('집에서 출발', _format(departure),
                    emphasis: true)),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 18, runSpacing: 8, children: [
                _TimeItem('첫 탑승', _format(plan.boardAt)),
                _TimeItem('예상 도착', _format(plan.arriveAt)),
              ]),
              const SizedBox(height: 10),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.directions_transit, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('첫 교통수단  ${_firstTransit(plan)}',
                    style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
              const SizedBox(height: 6),
              Text(minutes == null
                  ? '준비시간 정보가 없어 준비 시작 시각을 계산할 수 없어요.'
                  : '준비 $minutes분 + 이동 경로 소요시간 반영',
                  style: Theme.of(context).textTheme.bodySmall),
              if (plan.todos.isNotEmpty) ...[
                const SizedBox(height: 8),
                const Text('이동 전 추천 할 일',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                for (final todo in plan.todos.where((item) =>
                    '${item['status']}' == '포함' || '${item['status']}' == '대기').take(2))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('• ${todo['text'] ?? '할 일'} · ${todo['status'] ?? '상태 미정'}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
              if (plan.departureDerived)
                const Text('집에서 출발 시각은 예상 도착 시각에서 경로 총 소요시간을 역산한 값이에요.',
                    style: TextStyle(fontSize: 11)),
              if (readyAt != null && readyAt.isBefore(DateTime.now()) && !ApiConfig.demoMode)
                Text('권장 준비 시작 시각이 지났어요. 이동 계획을 다시 확인해 주세요.',
                    style: TextStyle(color: scheme.error, fontSize: 12)),
              if (ApiConfig.demoMode)
                const Text('서버의 고정 시연 시각이며 현재 시간의 실시간 예측이 아닙니다.',
                    style: TextStyle(fontSize: 11)),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: widget.onOpenRoutes,
                  icon: const Icon(Icons.arrow_forward, size: 18),
                  label: const Text('이동 탭에서 자세히 보기'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TimeItem extends StatelessWidget {
  const _TimeItem(this.label, this.value, {this.emphasis = false});
  final String label;
  final String value;
  final bool emphasis;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      Text(value, style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: emphasis ? 22 : 16,
        color: emphasis ? const Color(0xFF4936D8) : null,
      )),
    ],
  );
}
