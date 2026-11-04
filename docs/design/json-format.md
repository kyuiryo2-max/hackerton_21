# AI 출력 JSON 형식 (초안 — 11/5 오전 회의에서 확정)

AI는 아래 형식으로만 답해야 하고, 서버가 형식을 검사해요.
목록에 없는 값이 오면 거절하고 사용자에게 다시 물어요.

## 1. 할 일 → 장소 종류

입력: `"엄마 생신 선물 사야 해"`

```json
{
  "type": "todo",
  "text": "엄마 생신 선물",
  "place_types": ["꽃집", "케이크집"],
  "importance": null,
  "needs_confirm": false
}
```

- `place_types`: `data/demo/place_types.csv` 목록 안의 값만
- `importance`: 문장에 "꼭", "급해" 등이 있으면 `"필수"`, 없으면 `null` (사용자가 화면에서 선택)
- `needs_confirm`: 장소가 애매하면 `true` → 화면에서 사용자 확인

## 2. 질문 → 질문 종류 (핵심 기능, 11/5 변경)

질문은 자유롭게 받고, AI는 아래 8개 종류 중에서 고르기만 해요. 종류마다 서버 함수가 하나씩 붙어요.
질문 종류가 두 개 섞이면 `intents`에 순서대로 넣어요.

입력: `"늦을 것 같은데 약국은 들를 수 있어?"`

```json
{
  "type": "question",
  "intents": [
    { "intent": "running_late", "place_types": [], "delay_minutes": null },
    { "intent": "stopover_check", "place_types": ["약국"], "delay_minutes": null }
  ]
}
```

| intent | 예시 질문 | 서버가 하는 일 |
|---|---|---|
| `next_vehicle` | 다음 버스 언제야? | 도착 정보 조회 |
| `stopover_check` | 편의점 들렀다 가도 돼?, 아 우유 사야 돼 | **중요도 높은 할 일로 등록** → 장소 검색 + 최대로 쓸 수 있는 시간. 둘 다 안 되면 선택지 제시 |
| `running_late` | 10분 늦을 것 같아 | 출발 시각 재계산, 경유지 다시 판단, 다음 교통편 |
| `time_left` | 몇 분까지 나가면 돼? | 출발 시각 − 지금 |
| `change_todo` | 약은 안 사도 돼, 선물이 더 급해 | 할 일 삭제·중요도 변경 → 다시 계산 |
| `place_info` | 근처 약국 어디야? | 장소 검색 |
| `change_route` | 환승 적은 걸로 | 선호 기준 바꿔 경로 다시 정렬 |
| `unsupported` | 점심 뭐 먹지? | 지원하지 않는다고 안내 |

## 3. 답변 문장

서버가 계산한 결과만 AI에게 주고 한두 문장으로 만들어요.
답변 속 숫자가 계산 결과와 다르면(`llm.numbers_match`) AI 문장 대신 정해진 문장을 보여 줘요.
