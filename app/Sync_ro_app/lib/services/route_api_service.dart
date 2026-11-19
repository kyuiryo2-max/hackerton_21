import '../config/api_config.dart';
import '../models/route_candidate.dart';
import '../models/route_request.dart';
import '../data/presentation_demo_data.dart';
import '../data/demo_route_style.dart';
import 'server_plan_service.dart';
import 'server_route_adapter.dart';
import 'demo_service.dart';

class RouteSearchData {
  const RouteSearchData(this.routes, {this.plan, this.demoContext, this.notice});
  final List<RouteCandidate> routes;
  /// 화면에 잠깐 알려 줄 말 (예: 밤이라 첫차 기준으로 보여 줘요)
  final String? notice;
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
          '시연 경로(서울역 → 고려대학교)를 이용하거나, 서버 복구 후 '
          'SYNC_RO_OFFLINE_DEMO=false로 실행해 주세요.');
    }

    if (ApiConfig.demoMode && !_isBundledDemoPair(request)) {
      throw StateError('서버 시연 모드는 서울역 → 고려대학교 경로만 지원합니다. '
          '다른 지역의 실제 경로는 백엔드 일반 경로 계획 API가 준비된 뒤 이용할 수 있습니다.');
    }
    return _fetchRoutes(request);
  }

  bool _isBundledDemoPair(RouteRequest r) {
    final from = r.origin.replaceAll(' ', '');
    final to = r.destination.replaceAll(' ', '');
    // "서울대입구"까지 시연 경로로 잡히지 않게 서울역만 확인해요.
    return from == '서울역' &&
        (to.contains('고려대학교') || to.contains('고려대') || to.contains('안암'));
  }

  /// 이동 탭 시연 비교용 (내장 카카오 샘플 경로)
  List<RouteCandidate> demoRoutes() => _bundledDemoRoutes();

  List<RouteCandidate> _bundledDemoRoutes() {
    return [
      for (var i = 0; i < PresentationRoutes.routes.length; i++)
        RouteCandidate(
          id: 'offline_demo_${i + 1}',
          title: PresentationRoutes.routes[i].label,
          transferCount: PresentationRoutes.routes[i].transfers,
          isRecommended: i == 0,
          totalDurationMinutes: (PresentationRoutes.routes[i].durationSeconds / 60).ceil(),
          segments: [
            for (final leg in PresentationRoutes.routes[i].legs)
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
      // 직접 검색(홈 검색창·이동 탭 출발·도착 상자)은 일정이 아니라 고른 목적지로 찾아요.
      // 도착 희망 시간을 넣었으면 그 시각에서 거꾸로, 안 넣었으면 지금 출발 기준이에요 (11/16).
      // 목적지를 빼먹으면 서버가 가장 가까운 일정으로 계산해서 엉뚱한 길이 나와요 (11/13 발견).
      Future<ServerPlan> fetch({DateTime? departAt}) => service.fetch(
            originLat: request.originPlace?.latitude,
            originLng: request.originPlace?.longitude,
            destinationName: request.destinationPlace?.name ?? request.destination,
            destinationLat: request.destinationPlace?.latitude,
            destinationLng: request.destinationPlace?.longitude,
            departAt: departAt,
            arriveBy: departAt == null ? request.arriveBy : null,
            todoIds: request.todoIds,
          );
      var plan = await fetch();
      String? notice;
      // 밤이라 지금 다니는 차가 없으면 다음 첫차(05:30) 기준으로 다시 찾아요 (11/15)
      if (plan.noServiceNow && ServerPlan.isNight() && !ApiConfig.demoMode && request.arriveBy == null) {
        final first = ServerPlan.nextFirstTrain();
        final retry = await fetch(departAt: first);
        if (retry.routes.isNotEmpty) {
          plan = retry;
          final when = first.toUtc().add(const Duration(hours: 9));
          final today = DateTime.now().toUtc().add(const Duration(hours: 9)).day == when.day;
          notice = '지금은 다니는 차가 없어서 ${today ? '오늘' : '내일'} 첫차(05:30) 기준으로 보여 줘요';
        }
      }
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
      if (plan.noServiceNow) {
        throw StateError('지금은 탈 수 있는 대중교통이 없어요. 실시간 도착 정보가 있는 차가 없어서 운행이 끝난 것 같아요.');
      }
      return RouteSearchData([
        for (var i = 0; i < plan.routes.length; i++)
          ServerRouteAdapter.fromPlan(plan.routes[i], i, context: demoContext),
      ], plan: plan, demoContext: demoContext, notice: notice);
    } finally {
      service.dispose();
    }
  }

}
