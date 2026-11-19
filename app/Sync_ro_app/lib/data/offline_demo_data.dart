import 'dart:convert';

import 'presentation_demo_data.dart';

/// 오프라인 시연용 고정 예시. 실제 교통 정보가 아닙니다.
/// 시연 계획·컨텍스트는 [PresentationDemoData]의 서울역 → 고려대학교 값을 그대로 써요.
class OfflineDemoData {
  static final Map<String, dynamic> _examples =
      Map<String, dynamic>.from(jsonDecode(r'''{
        "arrivals": [
          {
            "arrivals": [
              {"route": "1호선·6호선", "minutes": 9, "next_minutes": 18, "direction": "동묘앞 방면"},
              {"route": "4호선·6호선", "minutes": 10, "next_minutes": 19, "direction": "삼각지 방면"},
              {"route": "173", "minutes": 5, "next_minutes": 13, "direction": "고려대학교앞 방면"}
            ]
          },
          {
            "arrivals": [
              {"route": "1호선·6호선", "minutes": 8, "next_minutes": null, "direction": "동묘앞 방면"},
              {"route": "4호선·6호선", "minutes": 0, "next_minutes": 9, "direction": "삼각지 방면"},
              {"route": "173", "minutes": 3, "next_minutes": null, "direction": "고려대학교앞 방면"}
            ]
          }
        ],
        "ask": [
          {
            "intents": [{"intent": "next_vehicle", "place_types": [], "delay_minutes": null}],
            "needs_confirm": false,
            "question": null,
            "result": {"intent": "next_vehicle", "route": "1호선·6호선", "minutes": 9, "next_minutes": 18},
            "answer": "1호선·6호선이 9분 뒤에 와요. 그다음 차는 18분 뒤예요.",
            "todo": null
          },
          {
            "intents": [{"intent": "stopover_check", "place_types": ["편의점"], "delay_minutes": null}],
            "needs_confirm": false,
            "question": null,
            "result": {
              "intent": "stopover_check",
              "feasible": true,
              "place": {"name": "GS25 S서울역1호점", "address": "서울 용산구 청파로 378 1층"},
              "max_stay_min": 4,
              "board_at": "2026-11-21T08:41:00+09:00"
            },
            "answer": "GS25 S서울역1호점에 들를 수 있어요. 최대 4분 있을 수 있어요.",
            "todo": {
              "text": "이어폰 사기",
              "place_types": ["편의점"],
              "importance": "필수",
              "status": "포함",
              "source": "질문"
            }
          },
          {
            "intents": [{"intent": "stopover_check", "place_types": [], "delay_minutes": null}],
            "needs_confirm": true,
            "question": "어디를 들르고 싶은지 알려 줄래요?",
            "result": null,
            "answer": "어디를 들르고 싶은지 알려 줄래요?",
            "todo": null
          },
          {
            "intents": [{"intent": "unsupported", "place_types": [], "delay_minutes": null}],
            "needs_confirm": false,
            "question": null,
            "result": {"intent": "unsupported"},
            "answer": "이동과 할 일에 관한 질문만 도와드릴 수 있어요.",
            "todo": null
          }
        ]
      }'''));

  static Map<String, dynamic> _copy(dynamic source) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(source)) as Map);

  static Map<String, dynamic> get context => PresentationDemoData.context;

  static Map<String, dynamic> arrivals({int elapsedSeconds = 0}) {
    final samples = _examples['arrivals'] as List;
    return _copy(samples[elapsedSeconds >= 600 ? 1 : 0]);
  }

  static Map<String, dynamic> get plan => PresentationDemoData.plan;

  static List<Map<String, dynamic>> get answers => (_examples['ask'] as List)
      .map((e) => _copy(e)).toList();
}
