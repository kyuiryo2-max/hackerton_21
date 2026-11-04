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

## 2. 질문 → 질문 종류 (2순위)

입력: `"편의점 들렀다 가도 돼?"`

```json
{
  "type": "question",
  "intent": "stopover_check",
  "place_types": ["편의점"],
  "delay_minutes": null
}
```

| intent | 예시 질문 | 서버가 하는 일 |
|---|---|---|
| `next_vehicle` | 다음 버스 언제야? | 도착 정보 조회 |
| `stopover_check` | 편의점 들렀다 가도 돼? | 장소 검색 + 최대로 쓸 수 있는 시간 |
| `running_late` | 10분 늦을 것 같아 | 출발 시각 재계산, 다음 교통편 |
| `unsupported` | 그 밖의 질문 | 지원하지 않는다고 안내 |
