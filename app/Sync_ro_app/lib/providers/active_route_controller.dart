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
  void setSearch(ActiveRouteSelection selection) { _active = selection; notifyListeners(); }
  void select(String id) {
    final current = _active;
    if (current == null || !current.routes.any((r) => r.id == id)) return;
    _active = ActiveRouteSelection(routes: current.routes, selectedId: id,
      origin: current.origin, destination: current.destination, arrival: current.arrival,
      plan: current.plan, demoContext: current.demoContext);
    notifyListeners();
  }
  void clearSearch() { _active = null; notifyListeners(); }
  void requestPlanRefresh() { _revision++; notifyListeners(); }
}

final activeRouteController = ActiveRouteController();
