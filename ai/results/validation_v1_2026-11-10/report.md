# 의도 분류 고도화 평가 보고서

- **평가 일시**: 2026-11-10
- **데이터셋 Split**: `validation` (40건)
- **Git SHA**: `unknown`
- **벡터 모델**: `jhgan/ko-sroberta-multitask` (m=2)
- **채택 정책**: `P2`

## 1. 컴포넌트별 분류 성능 비교 (Exact Match & Macro F1)

| 방식 (Method) | Exact Match | 95% Wilson CI | Macro Precision | Macro Recall | Macro F1 |
|---|---|---|---|---|---|
| **keyword** | 52.5% | [37.5%, 67.1%] | 0.798 | 0.486 | 0.604 |
| **vector** | 37.5% | [24.2%, 53.0%] | 0.738 | 0.457 | 0.565 |

## 2. 정책 라우팅 및 LLM 절감 지표

| 지표 (Metric) | 수치 | 95% Wilson CI | 설명 |
|---|---|---|---|
| **Coverage (자동 확정률)** | 55.0% | [39.8%, 69.3%] | LLM 호출 없이 규칙/벡터로 즉시 처리한 비율 |
| **Selective Risk (확정 오답률)** | 18.2% | [7.3%, 38.5%] | 자동 확정한 것 중 오답 비율 (품질 위험도) |
| **Fallback Rate (LLM 호출률)** | 45.0% | - | 보류되어 LLM으로 위임된 비율 (1 - Coverage) |
| **Unsupported Recall** | 87.5% | [52.9%, 97.8%] | 비지원 질문을 성공적으로 거절한 비율 |
| **Overall Accuracy** | 62.5% | [47.0%, 75.8%] | 시스템 전체 최종 의도 일치율 |

## 3. 주요 오분류 및 불일치 사례 분석 (Top Errors)

| ID | 질문 텍스트 | 기대 의도 | 키워드 | 벡터 (상태) | LLM | 최종 정책 | 통과 여부 |
|---|---|---|---|---|---|---|---|
| `VAL02` | 지하철 언제 오는지 봐줘 | `['next_vehicle']` | `['unsupported']` |  (abstained:low_score) | `[]` | `['unsupported']` | ❌ |
| `VAL05` | 약국 들렀다 가도 약속에 안 늦어? | `['stopover_check']` | `['running_late', 'stopover_check']` |  (abstained:too_many) | `[]` | `['unsupported']` | ❌ |
| `VAL14` | 나 몇 분 뒤에 출발하면 돼? | `['time_left']` | `['unsupported']` |  (abstained:too_many) | `[]` | `['unsupported']` | ❌ |
| `VAL15` | 출발 시각 몇 분 남았어? | `['time_left']` | `['next_vehicle']` |  (abstained:conflict) | `[]` | `['next_vehicle']` | ❌ |
| `VAL17` | 커피 사는 건 취소할게 | `['change_todo']` | `['unsupported']` |  (abstained:needs_context) | `[]` | `['unsupported']` | ❌ |
| `VAL18` | 다이소는 안 가도 돼 | `['change_todo']` | `['unsupported']` |  (abstained:conflict) | `[]` | `['unsupported']` | ❌ |
| `VAL19` | 보고서 인쇄가 제일 급해 | `['change_todo']` | `['unsupported']` |  (abstained:low_score) | `[]` | `['unsupported']` | ❌ |
| `VAL20` | 약 사기는 내일로 미룰게 | `['change_todo']` | `['unsupported']` |  (abstained:low_score) | `[]` | `['unsupported']` | ❌ |
| `VAL22` | 근처 다이소 몇 번 출구에 있어? | `['place_info']` | `['unsupported']` |  (abstained:too_many) | `[]` | `['unsupported']` | ❌ |
| `VAL23` | 이 편의점 24시간 영업해? | `['place_info']` | `['unsupported']` |  (abstained:low_score) | `[]` | `['unsupported']` | ❌ |
