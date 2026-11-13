import 'package:flutter/foundation.dart';
import '../models/route_candidate.dart';
import '../services/server_plan_service.dart';

/// Session-level selected route shared by Home and Navigation.
/// Search results are not persisted and cannot be confused with the server demo.
class ActiveRouteSelection {
  const ActiveRouteSelection({required this.routes, required this.selectedId,
    required this.origin, required this.destination, required this.arrival,
    this.plan, this.demoContext});
  final List<RouteCandidate> routes;
  final String selectedId;
  final String origin;
  final String destination;
  final DateTime arrival;
  final ServerPlan? plan;
  final Map<String, dynamic>? demoContext;
  RouteCandidate get selected => routes.firstWhere((r) => r.id == selectedId,
    orElse: () => routes.first);
}

class ActiveRouteController extends ChangeNotifier {
  ActiveRouteSelection? _active;
  ActiveRouteSelection? get active => _active;
  int _revision = 0;
  int get revision => _revision;
  void setSearch(ActiveRouteSelection selection) {
    _active = selection;
    notifyListeners();
  }

  /// 이동 탭에서 "이번 이동에 적용한" 할 일과 고른 경유지 (11/13).
  /// 어느 이동(목적지 + 도착 시각)에 적용했는지도 같이 기억해요.
  /// - 새로고침해도 같은 이동이면 적용이 그대로 남아요.
  /// - 홈은 자기가 보여 주는 일정과 같은 이동일 때만 경유지를 보여 줘요.
  String? _appliedTaskId;
  String? _appliedCandidateId;
  String? _appliedTrip;
  String? get appliedTaskId => _appliedTaskId;
  String? get appliedCandidateId => _appliedCandidateId;

  /// 이동 하나를 가리키는 키 (도착 시각은 분 단위로 비교)
  static String tripKey(String destination, DateTime? arriveBy) =>
      '$destination|${arriveBy == null ? '' : arriveBy.millisecondsSinceEpoch ~/ 60000}';

  bool appliedFor(String trip) => _appliedTaskId != null && _appliedTrip == trip;

  void setApplied(String? taskId, String? candidateId, String trip) {
    if (_appliedTaskId == taskId && _appliedCandidateId == candidateId && _appliedTrip == trip) return;
    _appliedTaskId = taskId;
    _appliedCandidateId = candidateId;
    _appliedTrip = taskId == null ? null : trip;
    notifyListeners();
  }
  void select(String id) {
    final current = _active;
    if (current == null || !current.routes.any((r) => r.id == id)) return;
    _active = ActiveRouteSelection(routes: current.routes, selectedId: id,
      origin: current.origin, destination: current.destination, arrival: current.arrival,
      plan: current.plan, demoContext: current.demoContext);
    notifyListeners();
  }
  void clearSearch() {
    _active = null;
    notifyListeners();
  }
  // Any task/schedule change invalidates a previous recommendation immediately.
  // Do not display stopovers from a plan calculated using deleted tasks.
  void requestPlanRefresh() {
    _active = null;
    _revision++;
    notifyListeners();
  }
}

final activeRouteController = ActiveRouteController();
