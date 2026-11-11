# 의도 분류 고도화 평가 보고서

- **평가 일시**: 2026-11-10
- **데이터셋 Split**: `validation` (40건)
- **Git SHA**: `cffbadd`
- **벡터 모델**: `jhgan/ko-sroberta-multitask` (m=2)
- **채택 정책**: `P2`

## 1. 컴포넌트별 분류 성능 비교 (Exact Match & Macro F1)

| 방식 (Method) | Exact Match | 95% Wilson CI | Macro Precision | Macro Recall | Macro F1 |
|---|---|---|---|---|---|
| **keyword** | 52.5% | [37.5%, 67.1%] | 0.798 | 0.486 | 0.604 |
| **vector** | 37.5% | [24.2%, 53.0%] | 0.738 | 0.457 | 0.565 |
| **llm** | 97.5% | [87.1%, 99.6%] | 0.976 | 1.000 | 0.988 |

## 2. 정책 라우팅 및 LLM 절감 지표

| 지표 (Metric) | 수치 | 95% Wilson CI | 설명 |
|---|---|---|---|
| **Coverage (자동 확정률)** | 55.0% | [39.8%, 69.3%] | LLM 호출 없이 규칙/벡터로 즉시 처리한 비율 |
| **Selective Risk (확정 오답률)** | 18.2% | [7.3%, 38.5%] | 자동 확정한 것 중 오답 비율 (품질 위험도) |
| **Fallback Rate (LLM 호출률)** | 45.0% | - | 보류되어 LLM으로 위임된 비율 (1 - Coverage) |
| **Unsupported Recall** | 87.5% | [52.9%, 97.8%] | 비지원 질문을 성공적으로 거절한 비율 |
| **Overall Accuracy** | 87.5% | [73.9%, 94.5%] | 시스템 전체 최종 의도 일치율 |

## 3. 주요 오분류 및 불일치 사례 분석 (Top Errors)

| ID | 질문 텍스트 | 기대 의도 | 키워드 | 벡터 (상태) | LLM | 최종 정책 | 통과 여부 |
|---|---|---|---|---|---|---|---|
| `VAL05` | 약국 들렀다 가도 약속에 안 늦어? | `['stopover_check']` | `['running_late', 'stopover_check']` |  (abstained:too_many) | `['stopover_check', 'time_left']` | `['stopover_check', 'time_left']` | ❌ |
| `VAL15` | 출발 시각 몇 분 남았어? | `['time_left']` | `['next_vehicle']` |  (abstained:conflict) | `['time_left']` | `['next_vehicle']` | ❌ |
| `VAL30` | 약 안 사고 바로 갈 건데 다음 버스 언제야? | `['change_todo', 'next_vehicle']` | `['next_vehicle']` |  (abstained:too_many) | `['change_todo', 'next_vehicle']` | `['next_vehicle']` | ❌ |
| `VAL32` | 커피 사려면 몇 분까지 나가야 돼? | `['stopover_check', 'time_left']` | `['time_left']` | stopover_check|time_left (accepted) | `['stopover_check', 'time_left']` | `['time_left']` | ❌ |
| `VAL40` | 지금 몇 시야? | `['unsupported']` | `['unsupported']` | time_left (accepted) | `['unsupported']` | `['time_left']` | ❌ |
