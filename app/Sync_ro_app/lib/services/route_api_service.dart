import '../config/api_config.dart';
import '../models/route_candidate.dart';
import '../models/route_request.dart';
import '../data/demo_route_options.dart';
import '../data/demo_route_style.dart';
import 'server_plan_service.dart';
import 'server_route_adapter.dart';
import 'demo_service.dart';

class RouteSearchData {
  const RouteSearchData(this.routes, {this.plan, this.demoContext});
  final List<RouteCandidate> routes;
  final ServerPlan? plan;
  final Map<String, dynamic>? demoContext;
}



class RouteApiService {
  Future<List<RouteCandidate>> searchRoutes(RouteRequest request) async =>
      (await searchWithDetails(request)).routes;

  Future<RouteSearchData> searchWithDetails(RouteRequest request) async {
    if (ApiConfig.offlineDemo) {
      if (_isBundledDemoPair(request)) return RouteSearchData(_bundledDemoRoutes());
      throw StateError('현재 오프라인 시연 모드입니다. 임의의 출발지·목적지는 실제 경로를 조회할 수 없습니다. '
          '시연 경로(안암역3번출구 → 청량리역)를 이용하거나, 서버 복구 후 '
          'SYNC_RO_OFFLINE_DEMO=false로 실행해 주세요.');
    }

    if (ApiConfig.demoMode && !_isBundledDemoPair(request)) {
      throw StateError('서버 시연 모드는 안암역 → 청량리역 경로만 지원합니다. '
          '다른 지역의 실제 경로는 백엔드 일반 경로 계획 API가 준비된 뒤 이용할 수 있습니다.');
    }
    return _fetchRoutes(request);
  }

  bool _isBundledDemoPair(RouteRequest r) {
    final from = r.origin.replaceAll(' ', '');
    final to = r.destination.replaceAll(' ', '');
    return (from.contains('안암역') || from.contains('안암')) &&
        (to.contains('청량리역') || to.contains('청량리'));
  }

  /// 이동 탭 시연 비교용 (내장 카카오 샘플 경로)
  List<RouteCandidate> demoRoutes() => _bundledDemoRoutes();

  List<RouteCandidate> _bundledDemoRoutes() {
    return [
      for (var i = 0; i < DemoRouteOptions.routes.length; i++)
        RouteCandidate(
          id: 'offline_demo_${i + 1}',
          title: DemoRouteOptions.routes[i].label,
          transferCount: DemoRouteOptions.routes[i].transfers,
          isRecommended: i == 0,
          totalDurationMinutes: (DemoRouteOptions.routes[i].durationSeconds / 60).ceil(),
          segments: [
            for (final leg in DemoRouteOptions.routes[i].legs)
              RouteSegment(
                type: switch (leg.mode) {
                  'BUS' => RouteSegmentType.bus,
                  'SUBWAY' => RouteSegmentType.subway,
                  _ => RouteSegmentType.walking,
                },
                description: leg.label,
                lineName: leg.mode == 'WALKING' ? '도보 환승' : leg.label.split(' (').first,
                startName: DemoRouteStyle.endpoints(leg).$1,
                endName: DemoRouteStyle.endpoints(leg).$2,
                durationMinutes: (leg.seconds / 60).ceil(),
                geometry: [
                  for (final p in leg.path)
                    RoutePoint(latitude: p.latitude, longitude: p.longitude),
                ],
              ),
          ],
        ),
    ];
  }

  Future<RouteSearchData> _fetchRoutes(RouteRequest request) async {
    // POST /api/plan, NOT the legacy sample-only /api/routes/search.
    final service = ServerPlanService();
    try {
      final plan = await service.fetch(
        originLat: request.originPlace?.latitude,
        originLng: request.originPlace?.longitude,
      );
      Map<String, dynamic>? demoContext;
      if (ApiConfig.demoMode) {
        final demoService = DemoService();
        try {
          demoContext = await demoService.getContext();
        } catch (_) {
          // A valid plan can still be shown without route geometry.
        } finally {
          demoService.dispose();
        }
      }
      return RouteSearchData([
        for (var i = 0; i < plan.routes.length; i++)
          ServerRouteAdapter.fromPlan(plan.routes[i], i, context: demoContext),
      ], plan: plan, demoContext: demoContext);
    } finally {
      service.dispose();
    }
  }

}
