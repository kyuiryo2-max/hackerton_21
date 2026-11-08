# AI 출력 JSON 형식 (확정 — #12 회의 11/6, 추가 결정 11/8)

AI는 아래 형식으로만 답해야 하고, 서버가 형식을 검사해요.
목록에 없는 값이 오면 거절하고 사용자에게 다시 물어요.
앱 ↔ 서버 API 모양은 [`api.md`](api.md)에 있어요.

| #12 회의 | 결정 | 이 문서 |
|---|---|---|
| 1 시각 | `+09:00` 붙이기 | api.md 공통 규칙 |
| 2 목적지 좌표 | lat, lng 저장 | api.md |
| 3 할 일 상태 | 상태(대기/포함/제외/완료) + 출처(입력/질문). 질문으로 들어온 경유는 필수 | 4번 |
| 4 질문 기록 | 표 추가. 최근 3~5턴을 AI에 보내고 테스트 케이스로 모음 | 5번 |
| 5 질문 되묻기 | 질문 출력에도 `needs_confirm` + `question` | 2번 |
| 6 시간 단위 | 서버 안은 초, 앱에는 분. 올림은 마지막에 한 번 | api.md 공통 규칙 |
| 7 장소 → 카카오 | `place_types.csv`의 카테고리 코드 또는 키워드 | `data/demo/place_types.csv` |
| 8 답변용 계산 결과 | **미정** (#37에서 정하기) | 3번 |
| 9 API 예시 | GitHub 서버 구조에 맞춤 | api.md, api-examples/ |

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
  ],
  "needs_confirm": false,
  "question": null
}
```

- `needs_confirm`: 무엇을 묻는지 알 수 없으면 `true`, `question`에 되묻는 짧은 문장 (11/6 회의 5번)
- 서버(`llm.normalize_question`)는 목록에 없는 질문 종류·장소 종류를 버리고, 질문 종류가 하나도 없으면 `needs_confirm: true`로 바꿔요. 되묻는데 문장이 없으면 기본 문장을 넣어요
- AI에는 질문과 함께 `context`(지금 할 일 등)와 `recent_messages`(최근 대화, 5번)를 보내요

입력: `"거기 들러도 돼?"` (최근 대화에 장소가 없음)

```json
{
  "type": "question",
  "intents": [{ "intent": "stopover_check", "place_types": [], "delay_minutes": null }],
  "needs_confirm": true,
  "question": "어디를 들르고 싶은지 알려 줄래요?"
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
계산 결과를 AI에 넘기는 JSON 모양은 아직 정하지 않았어요 (#12 회의 8번, #37에서 확정).

## 4. 할 일 저장: 상태와 출처 (11/8 회의 3번)

AI 출력(1번)을 사용자가 확인하면 `POST /api/todos`로 저장하고, 서버가 아래 두 값을 더해요.

| 필드 | 값 | 뜻 |
|---|---|---|
| `status` | `대기` | 새로 넣음, 아직 경로 판단 전 (필수인데 시간이 부족해 사용자 선택을 기다릴 때도) |
| | `포함` | 이번 경로에 넣음 |
| | `제외` | 이번엔 뺌 (시간 부족한 선택 할 일, 사용자가 뺌) |
| | `완료` | 끝냄 |
| `source` | `입력` | 할 일 화면에서 입력 |
| | `질문` | 이동 중 질문(`stopover_check`)에서 들어옴 → **`importance`는 항상 `필수`** |

예: `"아 우유 사야 돼"` → `stopover_check` → `{"text": "우유 사기", "place_types": ["편의점"], "importance": "필수", "status": "대기", "source": "질문"}`

## 5. 질문 기록 (11/8 회의 4번)

| 필드 | 값 |
|---|---|
| `role` | `user`(사용자 질문) / `assistant`(서버 답변) |
| `text` | 문장 |
| `intents` | 사용자 질문의 AI 분류 결과(2번의 `intents`). 답변은 `null` |
| `created_at` | `+09:00` 시각 |

- AI에는 최근 5턴(질문+답변 10개)을 `recent_messages`로 함께 보내요. "거기 말고 다른 데"처럼 앞 대화를 가리키는 질문용
- 쌓인 질문은 `scripts/export_questions.py`로 뽑아 정답을 채워 `ai/testcases/questions.csv`에 더해요
