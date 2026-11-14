# AI v3 설계 — 이동 중 들르기 위치 + 일정/할 일 추가 (초안)

> 2026-11-14. **구현 전 검토용 초안**이에요. 승인되면 `prompts/v3/`와 서버 코드에 반영합니다.
> 대상: ① 이동 중 들르기(현재 시각·이동 과정·상세 경로 삽입 위치) ② "나중에 해야 할 일" → 일정/할 일 버튼.

## 0. 지금 vs v3

| | 지금 (v2) | v3 |
|---|---|---|
| AI가 받는 상황 정보 | `context: {}` (항상 빔) | `context`에 지금 시각·이동 단계·상세 경로·할 일 목록 |
| 상세 경로 | AI 모름, 앱도 안 보냄 | `trip.steps`로 구간 목록 전송 |
| 들르기 답변 | "CU 안암센트럴점에 들를 수 있어요. 최대 6분" | + **어디에 넣는지**: "안암역 3번 출구로 걷는 길에, 최대 6분" |
| 일정 추가 | 의도 없음(`unsupported`) → 앱이 정규식으로 추측 | `add_schedule` 의도 + 서버가 슬롯 추출 |
| 할 일 추가 | `stopover_check`로만 처리(이동 중 들르기) | `add_todo` 의도 + `todo` 버튼 (자동 저장 안 함) |
| 의도 수 | 8개 | **10개** (+`add_schedule`, `add_todo`) |

핵심 원칙은 그대로: **AI는 분류·슬롯 추출만, 숫자·시각·삽입 위치는 서버 코드가 계산.** (환각 방지)

---

## 1. 앱 → 서버: `trip` v3 (`steps` 추가)

기존 필드는 그대로 두고 **선택 필드 2개**만 더해요. `steps`가 없으면 지금과 100% 똑같이 동작(하위 호환).

```json
"trip": {
  "phase": "to_stop",
  "now": "2026-11-21T08:36:12+09:00",
  "stop_name": "안암역 3번 출구",
  "board_at": "2026-11-21T08:44:00+09:00",
  "ride_name": "2115번",
  "arrive_at": "2026-11-21T08:59:17+09:00",
  "destination": "청량리역",
  "next_vehicles_min": [8, 16],

  "current_step": 0,
  "steps": [
    {"index": 0, "kind": "walk", "from": "현재 위치", "to": "안암역 3번 출구",
     "start": "2026-11-21T08:32:00+09:00", "end": "2026-11-21T08:36:00+09:00", "minutes": 4},
    {"index": 1, "kind": "wait", "at": "안암역 3번 출구",
     "start": "2026-11-21T08:36:00+09:00", "end": "2026-11-21T08:44:00+09:00", "minutes": 8},
    {"index": 2, "kind": "ride", "line": "2115번", "from": "안암역 3번 출구", "to": "청량리역환승센터",
     "start": "2026-11-21T08:44:00+09:00", "end": "2026-11-21T08:56:00+09:00", "minutes": 12},
    {"index": 3, "kind": "walk", "from": "청량리역환승센터", "to": "청량리역",
     "start": "2026-11-21T08:56:00+09:00", "end": "2026-11-21T08:59:00+09:00", "minutes": 3}
  ]
}
```

`kind`는 4종: `walk`(도보) · `wait`(대기) · `ride`(탑승) · `stay`(경유지 체류).
앱의 `RouteSegmentType`(walking/bus/subway/waiting)을 `bus`·`subway` → `ride`로 합치고, 경유지가 있으면 `stay`를 끼워요.

경유지가 있는 경우 예:

```json
"steps": [
  {"index": 0, "kind": "walk", "from": "현재 위치", "to": "CU 안암센트럴점", "start": "...", "end": "...", "minutes": 4},
  {"index": 1, "kind": "stay", "at": "CU 안암센트럴점", "start": "...", "end": "...", "minutes": 6},
  {"index": 2, "kind": "walk", "from": "CU 안암센트럴점", "to": "안암역 3번 출구", "start": "...", "end": "...", "minutes": 3},
  {"index": 3, "kind": "wait", "at": "안암역 3번 출구", "start": "...", "end": "...", "minutes": 5},
  {"index": 4, "kind": "ride", "line": "2115번", "from": "안암역 3번 출구", "to": "청량리역환승센터", "start": "...", "end": "...", "minutes": 12}
]
```

- 앱은 이미 `route.segments`와 구간별 시각(`_Timeline`과 같은 계산)을 갖고 있어서 그대로 변환만 하면 돼요.
- `current_step`: `trip.phase` 시점에 사용자가 있는 구간 index. 앱의 `TripPlan.steps` index와 같은 값.

---

## 2. 서버 → AI: `context` v3

`assistant._classify`가 지금은 `history`만 넘기는데, 아래를 채워 `llm.classify_question(context=...)`로 전달해요.

```json
"context": {
  "now": "2026-11-21T08:36:12+09:00",
  "today": "2026-11-21 (금)",
  "phase": "to_stop",
  "phase_label": "정류장으로 가는 중",
  "ride_name": "2115번",
  "board_at": "08:44",
  "arrive_at": "08:59",
  "destination": "청량리역",
  "current_step": 0,
  "steps": [
    {"index": 0, "kind": "walk", "label": "현재 위치 → 안암역 3번 출구", "start": "08:32", "end": "08:36"},
    {"index": 1, "kind": "wait", "label": "안암역 3번 출구에서 대기", "start": "08:36", "end": "08:44"},
    {"index": 2, "kind": "ride", "label": "2115번 탑승: 안암역 3번 출구 → 청량리역환승센터", "start": "08:44", "end": "08:56"}
  ],
  "todos": [
    {"text": "이어폰 사기", "place_types": ["편의점"], "status": "포함"}
  ],
  "recent_stopovers": ["CU 안암센트럴점"]
}
```

- `steps`는 **"여기·이 구간·타기 전"을 해석하는 용도**로만 줘요. AI가 index나 시각을 새로 만들지 않게 프롬프트에서 못 박습니다.
- `todos`는 `repo.list_todos` 결과(최대 10개, `text`/`place_types`/`status`만).
- 이동 중이 아니면 `context`에는 `now`·`today`·`todos`만 들어가고 `phase`/`steps`는 빠져요.

---

## 3. v3 프롬프트 초안 (`prompts/v3/question_intent.md`)

> v3 폴더에는 `question_intent.md`(아래) + v2의 `explain_result.md`·`todo_to_place.md`를 그대로 복사해요.
> `load_prompt`가 버전 폴더에서 세 파일을 모두 찾기 때문이에요.
> `.env`의 `LLM_PROMPT_VERSION=v3`로 전환하고, 문제가 생기면 `v2`로 되돌리면 돼요.

```markdown
<!-- v3: context 실사용 + 일정/할 일 추가 의도 -->
<!-- 2026-11-14: v2에 이어 (1) context(현재 시각·이동 단계·상세 경로·할 일) 사용 규칙을 실제로 넣고
     (2) add_schedule / add_todo 두 의도를 추가했다. AI는 여전히 분류·슬롯 추출만 한다. -->
너는 이동 중인 사용자의 질문을 아래 질문 종류(intents)로 분류하고 필요한 슬롯 값을 추출하는 AI다.
숫자를 임의로 계산하거나 답변 문장을 만들지 않는다. 오직 질문 분석과 JSON 추출만 수행한다.

## 0. 입력

{"question": "질문 문장", "context": {...}, "recent_messages": [...]}

context에는 지금 시각(now), 오늘 날짜와 요일(today), 이동 단계(phase, phase_label),
상세 경로(steps, current_step), 이미 등록된 할 일(todos), 이번 이동에 이미 들르기로 한 곳(recent_stopovers)이 들어 있다.
- "오늘·내일·모레·이번 주·다음 주"는 context.today를 기준으로 해석한다. context에 없는 날짜를 추측하지 않는다.
- context.steps는 사용자가 말하는 "여기·이 구간·지나가는 길·타기 전"을 찾는 데만 쓴다.
  - step_index, 시각, 소요 시간 같은 숫자를 새로 만들지 않는다. 그 값은 서버가 계산한다.
- context.todos에 같은 일이 이미 있으면 add_todo가 아니라 change_todo를 고른다.
  - 예: todos에 "우유 사기"가 있는데 "우유 사야 해"라고 하면 add_todo가 아니라 change_todo(raise)다.
- context.recent_stopovers에 있는 곳을 또 물으면 stopover_check로 분류하되, 새 할 일을 만들지 않는다(서버가 판단).

## 1. 질문 종류 (10대 의도 및 판정 기준)

- next_vehicle: 탈것(버스·지하철·열차)의 도착 시각, 다음 차량 도착까지 남은 대기 시간 문의
  - 예: "다음 버스 언제야?", "지하철 몇 분 남았어?", "273번 아직 멀었어?", "다음 열차 몇 분 뒤에 와?"
  - 주의: 사용자 자신의 출발/나갈 시간 문의(time_left)와 엄격히 구분한다.
- time_left: 사용자 자신이 출발해야 하는 시각, 준비에 남은 여유 시간 문의
  - 예: "몇 분까지 나가면 돼?", "나 지금 바로 나가야 돼?", "준비 얼마나 더 해도 돼?", "언제 나가야 돼?"
  - 주의: 탈것 도착 시간(next_vehicle)이 아니라 사용자 본인의 출발 시점 문의다.
- running_late: 약속이나 일정에 늦어짐(지각, 밀림, 늦게 출발)을 알림
  - 추출: delay_minutes (지연 분 정수, 예: "10분 늦을 것 같아" → 10, "15분 정도 밀릴 듯" → 15, "5분 늦게 나가는데" → 5)
  - 주의: "N분 늦게 나가/출발해"처럼 늦음이 포함된 경우 time_left가 아니라 running_late다.
  - "지금 출발하면 늦어?", "지금 나가면 안 늦어?"처럼 지금 기준으로 늦는지 묻는 질문도 running_late이고 delay_minutes는 0이다.
  - 핵심 규칙: 구체적 지연 분이 없는 경우("버스 하나 놓쳤어", "늦을 것 같아")는 delay_minutes를 null로 하고,
    needs_confirm을 true로 설정하여 question에 "몇 분 늦을 것 같아요?"라고 되묻는다.
- stopover_check: 이동 경로상 특정 장소나 할 일을 경유할 수 있는지 가능성·시간 문의
  - 추출: place_types (아래 허용 목록에서 선택)
  - 예: "편의점 들렀다 가도 돼?", "아 우유 사야 돼", "정류장 옆 다이소 잠깐 가도 될까"
  - 두 군데 이상을 모두 들르려는 질문("편의점 들렀다가 약국도 갈 수 있어?")은 stopover_check를 장소마다 하나씩 넣는다.
    한 stopover_check의 place_types가 여러 개면 "그중 한 곳"이라는 뜻이다.
- place_info: 장소 자체의 위치뿐만 아니라 "영업시간(마감 시각)", "전화번호" 등 장소 상세 정보 문의
  - 추출: place_types (아래 허용 목록에서 선택)
  - 예: "근처 약국 어디야?", "여기서 제일 가까운 ATM", "그 약국 몇 시에 닫아?" (영업 마감 시각 질문도 place_info다)
- change_todo: 할 일의 삭제("안 사도 돼", "다음에 할게"), 완료("샀어", "다녀왔어") 또는 중요도 변경("더 급해")
  - 추출: action ("delete" | "done" | "raise" | "lower"), todo_text
  - 예: "우유는 샀어" → action: "done", todo_text: "우유"
  - 예: "약은 안 사도 돼" → action: "delete", todo_text: "약"
  - 예: "선물이 더 급해" → action: "raise", todo_text: "선물"
  - 예: "출력은 학교 가서 할게" → action: "delete", todo_text: "과제 출력"
- change_route: 경로 탐색 선호 조건(환승 최소, 최단 시간, 최소 요금 등) 변경
  - 추출: preference ("transfer" | "time" | "fare")
  - 예: "환승 적은 걸로" → "transfer", "돈 덜 드는 쪽으로 가자" → "fare", "빠른 걸로" → "time"
- add_schedule: 앞으로의 일정을 새로 등록해 달라는 요청
  - 추출: title, location, when{day_ref, weekday, month, day, hour, minute, ampm, duration_minutes}
  - 예: "내일 오후 3시에 강남역에서 치과 예약 추가해 줘"
  - 예: "11월 25일 저녁 7시 팀 회의 일정 잡아 줘"
  - 예: "다음 주 화요일 9시 반에 병원 가는 일정 등록해 줘"
  - **요청 표현이 있어야 한다**: "추가·등록·잡아·넣어·만들어·저장·기억해" 중 하나.
    - "내일 3시까지 광화문에 가야 해"처럼 요청 표현이 없으면 add_schedule이 아니다(일정을 새로 만들라는 말이 아님).
  - when 작성 규칙:
    - day_ref: "today" | "tomorrow" | "day_after_tomorrow" | "weekday_this" | "weekday_next" | "explicit" | null
    - weekday: "월"~"일" (day_ref가 weekday_this/weekday_next일 때)
    - month, day: 사용자가 "11월 25일", "25일"처럼 **직접 말한 숫자만** 채운다. (day_ref가 explicit일 때)
      - "25일"처럼 월이 없으면 month는 null로 둔다(서버가 이번 달/다음 달을 정한다).
    - hour: 사용자가 말한 시 (1~12 또는 0~23 그대로), minute: 말한 분(없으면 0)
    - ampm: "오전" → "am", "오후·저녁·밤" → "pm", 말하지 않았으면 null
    - duration_minutes: "한 시간", "30분"처럼 길이를 말했을 때만 정수로. 아니면 null
  - **절대 하지 말 것**: 날짜 계산(2026-11-15 만들기), "내일"을 날짜로 바꾸기, 시각 더하기. 전부 서버가 한다.
- add_todo: 지금 이동과 별개로 "나중에 해야 할 일"을 목록에 남기려는 요청
  - 추출: text, place_types, importance
  - 예: "나중에 약국에서 약 사기", "이따 저녁에 택배 찾아야 해", "집 가서 빨래해야지"
  - text는 "~기" 형태의 짧은 명사구로 만든다: "약 사기", "택배 찾기", "빨래하기".
  - **stopover_check와 구분**:
    - 지금 이 이동에서 들를 수 있는지 묻거나("들러도 돼?", "갈 수 있어?") 미래 표현이 없으면 stopover_check.
      - "아 우유 사야 돼" → stopover_check (v2 동작 유지)
    - "나중에·이따·저녁에·내일·모레·집 가서"처럼 **나중 일**임이 드러나면 add_todo.
    - 한 문장에 둘 다 있으면 둘 다 넣는다: "지금 편의점 들러서 우유 사고, 나중에 약국에서 약 사기"
      → [stopover_check(편의점), add_todo(text: "약 사기", place_types: ["약국"])]
  - 여러 개를 나열하면("약 사고 택배도 찾아야 해") add_todo를 항목마다 하나씩 넣는다.
  - importance: "꼭·급해·잊지 말고"가 있으면 "필수", 아니면 null.
- unsupported: 틈길 서비스 범위를 벗어난 일반 질문 (날씨, 맛집, 잡담 등)
  - 예: "점심 뭐 먹지?", "오늘 비 와?", "노래 틀어줘"

## 2. 규칙

- place_types는 반드시 이 허용 목록 안의 값만 사용한다: {{PLACE_TYPES}}
  - 일상 물품/어휘 매핑:
    - 우유, 간식, 삼각김밥, 음료 → ["편의점"] 또는 ["편의점", "마트"]
    - 약, 타이레놀, 감기약, 밴드 → ["약국"]
    - 커피, 아아, 라떼 → ["카페"]
    - 현금, ATM, 출금 → ["은행·ATM"]
    - 출력, 인쇄, 복사, 프린트 → ["프린트"]
    - 멀티탭, 생활용품 → ["다이소"]
    - 화장품 → ["올리브영"]
- 복합 질문: 사용자가 두 가지 의도를 함께 말하면 intents 배열에 **말한 순서대로** 모두 넣는다.
- context.todos의 현재 할 일 목록을 참고한다. recent_messages는 최근 대화다.
  "거기", "그거"처럼 앞 대화를 가리키면 recent_messages에서 찾는다.
  - 예: 앞 대화에서 "근처 약국 어디야?"라고 물었으면, "거기 들러도 돼?"는 stopover_check + place_types ["약국"]이다.
  - 앞 대화에도 장소가 없으면 place_types를 비우고 needs_confirm을 true로 한다.
- 모호함 처리: 무엇을 묻는지 알 수 없거나 필수 정보(장소, 지연 분, 일정 제목 등)가 누락되면
  needs_confirm을 true로 하고 question에 짧고 친절한 되묻는 문장을 쓴다. 명확하면 needs_confirm은 false, question은 null.
  - add_schedule에서 **제목**이 없으면 되묻는다: "무슨 일정인지 알려 줄래요?"
  - add_schedule에서 날짜·시각이 없어도 되묻지 않는다. 서버가 기본값을 채우고 화면에서 확인받는다.
- 응답은 마크다운 코드블록 없이 오직 순수한 JSON 객체 하나만 출력한다.

## 3. 출력 JSON 예시

단일 의도 (들르기):
{"type": "question", "intents": [{"intent": "stopover_check", "place_types": ["편의점"], "delay_minutes": null}], "needs_confirm": false, "question": null}

복합 의도 (늦어짐 + 경유 확인):
질문: "늦을 것 같은데 약국은 들를 수 있어?"
출력: {"type": "question", "intents": [{"intent": "running_late", "place_types": [], "delay_minutes": null}, {"intent": "stopover_check", "place_types": ["약국"], "delay_minutes": null}], "needs_confirm": false, "question": null}

되묻기 (지연 분 누락):
질문: "버스 하나 놓쳤어"
출력: {"type": "question", "intents": [{"intent": "running_late", "place_types": [], "delay_minutes": null}], "needs_confirm": true, "question": "몇 분 늦을 것 같아요?"}

일정 추가:
질문: "내일 오후 3시에 강남역에서 치과 예약 추가해 줘" (context.today = 2026-11-14 금)
출력: {"type": "question", "intents": [{"intent": "add_schedule", "title": "치과 예약", "location": "강남역", "when": {"day_ref": "tomorrow", "weekday": null, "month": null, "day": null, "hour": 3, "minute": 0, "ampm": "pm", "duration_minutes": null}, "place_types": []}], "needs_confirm": false, "question": null}

일정 추가 (날짜만, 시각 없음):
질문: "11월 25일 병원 가는 일정 등록해 줘"
출력: {"type": "question", "intents": [{"intent": "add_schedule", "title": "병원 가기", "location": "", "when": {"day_ref": "explicit", "weekday": null, "month": 11, "day": 25, "hour": null, "minute": null, "ampm": null, "duration_minutes": null}, "place_types": []}], "needs_confirm": false, "question": null}

할 일 추가:
질문: "나중에 약국에서 약 사기"
출력: {"type": "question", "intents": [{"intent": "add_todo", "text": "약 사기", "place_types": ["약국"], "importance": null}], "needs_confirm": false, "question": null}
```

---

## 4. `stopover_check` 응답에 `insert_at` 추가

`result`에 아래 필드를 더해요. **서버 코드가 계산**하고, AI는 관여하지 않아요.

```json
{
  "intent": "stopover_check",
  "feasible": true,
  "place": {"name": "CU 안암센트럴점", "address": "서울 동대문구 안암로28길 16"},
  "max_stay_min": 6,
  "board_at": "2026-11-21T08:44:00+09:00",
  "insert_at": {
    "step_index": 0,
    "position": "during",
    "step_kind": "walk",
    "step_label": "현재 위치 → 안암역 3번 출구",
    "label": "안암역 3번 출구로 걷는 길에",
    "reason": "찾은 장소가 정류장까지 걷는 구간에 있어요"
  }
}
```

| 필드 | 값 | 뜻 |
|---|---|---|
| `step_index` | 정수 | 삽입할 `trip.steps` index |
| `position` | `during` / `before` / `after` / `at` | 그 구간 안 / 시작 전 / 끝난 뒤 / 그 장소에서 |
| `step_kind` | walk·wait·ride·stay | 구간 종류 |
| `step_label` | 문자열 | 구간 자체 설명 ("현재 위치 → 안암역 3번 출구") |
| `label` | 문자열 | 답변에 그대로 쓰는 말 ("…로 걷는 길에", "…에서 기다리는 동안") |
| `reason` | 문자열 | 왜 그 위치인지 (디버깅·설명용) |

### 계산 규칙 (우선순위, 결정적)

1. `phase == "at_place"` → 지금 있는 `stay` 구간, `position: "at"`, label `"{place_name}에 있는 동안"`.
2. 찾은 장소 이름이 `steps[].from/to/at`에 들어 있으면 → 그 구간, `position: "during"`.
3. 도보 구간의 도착지가 탑승 정류장과 같으면 → 그 도보 구간, `position: "during"`, label `"{정류장}으로 걷는 길에"`.
4. 그 외(정류장 인근) → 마지막 `wait` 구간, `position: "at"`, label `"{정류장}에서 기다리는 동안"`.
5. 장소가 목적지 쪽에 더 가까우면 → 마지막 `walk`, `position: "after"`, label `"도착한 뒤"`.
6. `steps`가 없으면 → `insert_at: null` (지금 문장 그대로, 하위 호환).

불가능할 때:

```json
{
  "intent": "stopover_check",
  "feasible": false,
  "place": {"name": "CU 안암센트럴점", "address": "..."},
  "max_stay_min": null,
  "board_at": null,
  "insert_at": null
}
```

답변 문장은 코드가 이렇게 만져요(기존 문장 + 위치):

- 전: `CU 안암센트럴점에 들를 수 있어요. 최대 6분 있을 수 있어요.`
- 후: `안암역 3번 출구로 걷는 길에 CU 안암센트럴점에 들를 수 있어요. 최대 6분 있어도 돼요.`

---

## 5. `add_schedule` 응답

```json
{
  "intents": [
    {"intent": "add_schedule", "title": "치과 예약", "location": "강남역",
     "when": {"day_ref": "tomorrow", "weekday": null, "month": null, "day": null,
              "hour": 3, "minute": 0, "ampm": "pm", "duration_minutes": null},
     "place_types": []}
  ],
  "needs_confirm": false,
  "question": null,
  "result": {
    "intent": "add_schedule",
    "schedule": {
      "title": "치과 예약",
      "location": "강남역",
      "start_time": "2026-11-15T15:00:00+09:00",
      "end_time": "2026-11-15T16:00:00+09:00"
    },
    "assumed": []
  },
  "schedule": { "...": "result.schedule 와 같은 값 (앱이 result가 다른 의도일 때도 읽을 수 있게)" },
  "answer": "내일 오후 3시 치과 예약으로 일정 초안을 만들었어요. 아래에서 확인하고 추가해 주세요.",
  "todo": null,
  "engine": "ai"
}
```

- **저장하지 않아요.** 앱의 기존 "일정 추가" 버튼 → 일정 입력 화면(`ScheduleFormScreen`)에서 사용자가 확인해야 저장돼요.
- 시각·날짜가 없으면 서버 기본값으로 채우고 `assumed`에 표시해요:
  - 날짜 없음 → 오늘 (`assumed: ["date"]`)
  - 시각 없음 → 다음 정시, 09시 이전이면 09:00 (`assumed: ["time"]`)
  - 길이 없음 → 60분 (`assumed: ["duration"]`)
  - 답변 문장에 "시각은 오전 9시로 채워 뒀어요. 화면에서 바꿀 수 있어요."를 덧붙여요.
- `needs_confirm`은 **제목이 없을 때만** true. 그래야 앱이 버튼을 계속 보여 줄 수 있어요.

앱 쪽 변경(작음):

```dart
// assistant_screen.dart
final draft = ScheduleDraft.fromServerResult(response.result)
    ?? ScheduleDraft.fromServerResult(response.schedule)   // ← 추가
    ?? (intent == 'unsupported' ? ScheduleDraft.parseLocal(message, DateTime.now()) : null);
```

`server_ask_service.dart`에 `schedule` 필드 하나 추가하면 끝이에요.

---

## 6. `add_todo` 응답

```json
{
  "intents": [
    {"intent": "add_todo", "text": "약 사기", "place_types": ["약국"], "importance": null}
  ],
  "needs_confirm": false,
  "question": null,
  "result": {
    "intent": "add_todo",
    "text": "약 사기",
    "place_types": ["약국"],
    "importance": null,
    "can_add_todo": true
  },
  "answer": "약국에서 약 사기, 잊지 않게 할 일로 남겨 둘 수 있어요.",
  "todo": {
    "text": "약 사기", "place_types": ["약국"], "importance": null,
    "status": "대기", "source": "질문"
  },
  "todos": [{ "...": "todo 와 같은 값" }],
  "engine": "ai"
}
```

- `todo`에 **`id`를 넣지 않아요** = 자동 저장하지 않음. 앱은 `id`가 없으면 "할 일 목록에 추가" 버튼을 보여 줘요(지금 코드 그대로).
- 앱 버튼 → 확인 다이얼로그 → `TodoController.addTodo` (로컬 저장 + 계획 새로고침).
- `stopover_check`의 `todo`(자동 저장, `id` 있음)와 구분돼요. 그건 지금처럼 동작해요.

복합 예: "지금 편의점 들러서 우유 사고, 나중에 약국에서 약 사기"

```json
"intents": [
  {"intent": "stopover_check", "place_types": ["편의점"], "delay_minutes": null},
  {"intent": "add_todo", "text": "약 사기", "place_types": ["약국"], "importance": null}
],
"result": { "...": "마지막 의도(add_todo) 결과" },
"todo": { "text": "약 사기", ... },
"answer": "편의점에 들를 수 있어요. 최대 8분 있어도 돼요. 약국에서 약 사기, 잊지 않게 할 일로 남겨 둘 수 있어요."
```

---

## 7. 바뀌는 파일 (구현 시)

| 파일 | 변경 |
|---|---|
| `server/app/prompts/v3/{question_intent,explain_result,todo_to_place}.md` | 신규 (question_intent만 새로, 나머지는 v2 복사) |
| `server/app/services/llm.py` | `INTENTS`에 `add_schedule`,`add_todo` 추가 |
| `server/app/services/trip.py` | `TripStep`, `steps`, `current_step` 스키마 + `_minutes` 재사용 |
| `server/app/services/assistant.py` | `_classify`에 `context` 전달, `insert_at` 계산, `add_schedule`/`add_todo` 핸들러, `schedule` 응답 필드 |
| `server/app/services/rules.py` | AI 없을 때 폴백: "나중에 … 사야" → add_todo, "…일정 추가" → add_schedule |
| `server/app/services/place_time.py` (신규, 선택) | `when` 슬롯 → ISO 변환 (코드가 날짜 계산) |
| `server/app/routers/assistant.py` | 응답에 `schedule` 필드(스키마 아님, dict라 그대로) |
| `app/.../server_ask_service.dart` | `schedule` 파싱 |
| `app/.../assistant_screen.dart` | `response.schedule` 폴백 1줄 |
| `app/.../trip_progress.dart` | `toAskJson`에 `steps`/`current_step` |
| `app/.../move_route_planner.dart` | `steps` 생성(세그먼트 + 시각), 응답 `insert_at` 표시 |
| `docs/design/json-format.md`, `api-examples/ask.json` | 의도 10개·예시 갱신 |

## 8. 테스트 계획

프롬프트·코드 분리 원칙에 맞춰 **AI 없이도 도는 테스트**를 먼저 넣어요.

1. `insert_at` 계산 (스텁 trip)
   - 도보 구간에 장소 → `during` / 0
   - `phase == "at_place"` → `at` / stay 구간
   - 정류장 인근 → `at` / wait 구간
   - 목적지 인근 → `after` / 마지막 walk
   - `steps` 없음 → `null` (기존 응답과 동일 = 회귀 없음)
   - 불가능 → `null`
2. `when` → ISO 변환
   - 오늘/내일/모레, 이번 주 화요일, 다음 주 화요일, 11월 25일, 25일(월 생략), 오후 3시, 3시(ampm 없음), 9시 반
   - 날짜·시각 없음 → 기본값 + `assumed`
   - 연말 경계(12/31 "내일" → 1/1)
3. 의도 추가 회귀
   - "아 우유 사야 돼" → 여전히 `stopover_check` (v2 동작 유지)
   - "나중에 약국에서 약 사기" → `add_todo`
   - "내일 3시까지 광화문에 가야 해" → `add_schedule` 아님
   - add_schedule/add_todo는 DB에 저장되지 않음 (`todo["id"] is None`)
   - demo 사용자에서도 버튼용 초안이 나옴
4. 기존 416개 테스트 전부 통과 (`context`/`steps` 없으면 동작 동일)

## 9. 확인이 필요한 결정 3개

1. **기본값 정책**: 날짜·시각이 없을 때 서버가 채울까요?
   - (권장) 채우고 `assumed`로 알린다 → 버튼이 항상 뜬다. 지금 안은 이쪽.
   - 대안: 되묻기 → 정확하지만 버튼이 안 뜨고 대화가 한 번 더 필요.
2. **`add_todo` 자동 저장 여부**: (권장) 저장 안 하고 버튼. 지금 안은 이쪽.
3. **"아 우유 사야 돼"의 분류**: (권장) v2처럼 `stopover_check` 유지. "나중에"가 붙을 때만 `add_todo`.
