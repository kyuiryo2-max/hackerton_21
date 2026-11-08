import 'dart:convert';

/// Frozen API examples bundled into Dart so no asset/pubspec changes are required.
/// Source: api-examples.zip (demo_context, arrivals, ask, plan).
/// Demo-only data, NOT live transit information.
class OfflineDemoData {
  static final Map<String, dynamic> _examples =
      Map<String, dynamic>.from(jsonDecode(r'''{"demo_context":[{"now":"2026-11-21T08:32:00+09:00","location":{"name":"안암역3번출구 정류장","lng":127.03045087,"lat":37.58624821},"schedule":{"destination":{"name":"청량리역","lng":127.04691,"lat":37.58029},"arrive_by":"2026-11-21T09:00:00+09:00","prep_minutes":30},"stop":{"ars_id":"08301","station_id":"107000205","name":"안암역3번출구"},"route":{"type":"BUS","name":"2115","guidance":"지선 2115 (안암역3번출구 > 청량리역환승센터)","moving_seconds":797,"last_walk_seconds":120,"transfers":0,"fare_min":1500,"fare_max":1500,"stops":["안암역3번출구","제기시장","홍파초등학교.정화여중고","제기동주민센터.서울약령시앞","청량리수산시장","청량리역환승센터"]}}],"arrivals":[{"arrivals":[{"route":"2115","minutes":12,"next_minutes":20,"direction":"중랑공영차고지"},{"route":"273","minutes":3,"next_minutes":10,"direction":"중랑공영차고지"}]},{"arrivals":[{"route":"2115","minutes":2,"next_minutes":10,"direction":"중랑공영차고지"},{"route":"273","minutes":0,"next_minutes":null,"direction":"중랑공영차고지"}]}],"ask":[{"intents":[{"intent":"next_vehicle","place_types":[],"delay_minutes":null}],"needs_confirm":false,"question":null,"result":{"intent":"next_vehicle","route":"2115","minutes":12,"next_minutes":20},"answer":"2115번이 12분 뒤에 와요. 그다음 차는 20분 뒤예요.","todo":null},{"intents":[{"intent":"stopover_check","place_types":["편의점"],"delay_minutes":null}],"needs_confirm":false,"question":null,"result":{"intent":"stopover_check","feasible":true,"place":{"name":"CU 안암센트럴점","address":"서울 성북구 고려대로28길 16"},"max_stay_min":6,"board_at":"2026-11-21T08:44:00+09:00"},"answer":"CU 안암센트럴점에 들를 수 있어요. 최대 6분 있을 수 있어요.","todo":{"text":"이어폰 사기","place_types":["편의점"],"importance":"필수","status":"포함","source":"질문"}},{"intents":[{"intent":"stopover_check","place_types":[],"delay_minutes":null}],"needs_confirm":true,"question":"어디를 들르고 싶은지 알려 줄래요?","result":null,"answer":"어디를 들르고 싶은지 알려 줄래요?","todo":null},{"intents":[{"intent":"unsupported","place_types":[],"delay_minutes":null}],"needs_confirm":false,"question":null,"result":{"intent":"unsupported"},"answer":"이동과 할 일에 관한 질문만 도와드릴 수 있어요.","todo":null}],"plan":[{"now":"2026-11-21T08:32:00+09:00","schedule":{"destination":{"name":"청량리역","lng":127.04691,"lat":37.58029},"arrive_by":"2026-11-21T09:00:00+09:00","prep_minutes":30},"board_at":"2026-11-21T08:44:00+09:00","arrive_at":"2026-11-21T08:59:17+09:00","routes":[{"rank":1,"type":"BUS","name":"2115","guidance":"지선 2115 (안암역3번출구 > 청량리역환승센터)","total_min":28,"wait_min":12,"moving_min":14,"last_walk_min":2,"transfers":0,"fare":1500,"stops":["안암역3번출구","제기시장","홍파초등학교.정화여중고","제기동주민센터.서울약령시앞","청량리수산시장","청량리역환승센터"],"max_stay_min":6,"has_realtime":true}],"todos":[{"todo_id":1,"text":"이어폰 사기","importance":"필수","status":"포함","place":{"place_type":"편의점","name":"CU 안암센트럴점","address":"서울 성북구 고려대로28길 16"},"detour_min":4,"reason":""},{"todo_id":3,"text":"다이소 들르기","importance":"필수","status":"대기","place":{"place_type":"다이소","name":"다이소 안암점","address":"서울 성북구 고려대로24길 51"},"detour_min":12,"reason":"시간이 부족해요","options":["이번엔 빼기","늦더라도 들르기"]},{"todo_id":2,"text":"커피 사기","importance":"선택","status":"제외","place":{"place_type":"카페","name":"스타벅스 안암역점","address":"서울 성북구 고려대로 102-2"},"detour_min":2,"reason":"시간이 부족해요"}],"explanation":"2115번을 타면 이어폰을 사고도 9시 전에 도착해요."}]}'''));

  static Map<String, dynamic> _copy(dynamic source) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);

  static Map<String, dynamic> get context => _copy((_examples['demo_context'] as List).first);
  static Map<String, dynamic> arrivals({int elapsedSeconds = 0}) {
    final samples = _examples['arrivals'] as List;
    return _copy(samples[elapsedSeconds >= 600 ? 1 : 0]);
  }
  static Map<String, dynamic> get plan => _copy((_examples['plan'] as List).first);
  static List<Map<String, dynamic>> get answers => (_examples['ask'] as List)
      .map((e) => _copy(e)).toList();
}
