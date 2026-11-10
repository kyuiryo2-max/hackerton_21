# 의도 분류 라벨링 가이드 (Labeling Guide)

이 문서는 AI 의도 분류기(규칙, 벡터 Top-m, LLM)의 라벨 일관성을 유지하고, 평가 데이터셋을 감사하기 위한 단일 기준입니다.
원칙: **"명시적 표현만 라벨링한다 (Strict Explicit Labeling)"** — 사용자의 잠재적 의도를 추측하여 라벨을 부여하지 않습니다.

---

## 1. 7개 핵심 의도 정의 및 경계 기준

| 의도 (Intent) | 확정 정의 (Inclusion) | 제외 기준 (Exclusion) | 필수/선택 슬롯 |
|---|---|---|---|
| `next_vehicle` | **탈것(버스·지하철)**의 도착 시각, 출발 시각, 남은 대기 시간 | 사용자 자신의 출발/나갈 시각 (`time_left`) | - |
| `time_left` | **사용자 자신**이 출발해야 하는 시각, 준비에 남은 여유 시간 | 탈것의 도착 시간 (`next_vehicle`) | - |
| `running_late` | 늦을 것 같다는 **명시적 표현**(지각, 늦음, 밀림) 또는 구체적 지연 시간 | 단순히 "버스 놓쳤어" 등 상황 서술만 있는 경우 | `delay_minutes` |
| `stopover_check` | 경로 이동 중 특정 장소(편의점, 약국 등)를 **경유 가능한지** 확인 | 장소 자체의 기본 정보 조회 (`place_info`) | `place_types`, `todo_text` |
| `place_info` | 장소의 위치, **영업 시간(마감 시각)**, 연락처 등 장소 자체의 정보 | 경로상 경유 가능 여부 문의 (`stopover_check`) | `place_types` |
| `change_todo` | 할 일의 명시적 삭제("안 사도 돼"), 순서/우선순위 변경 | 단순 할 일 언급, 할 일 완료 여부 문의 | `action`, `todo_text` |
| `change_route` | 경로 탐색 옵션 변경 (최소 환승, 빠른 경로, 최소 요금 등) | 단순한 현재 경로 재안내 요청 | `preference` |
| `unsupported` | 틈길 시스템의 기능 범위를 벗어난 일반 질문 (날씨, 맛집, 잡담) | 지원 의도로 분류 가능한 질문 | - |

---

## 2. 기존 25건 테스트 케이스 재감사 (Audit)

기존 `questions.csv` 25건 중 발견된 라벨 불일치 및 경계 사례에 대한 처리 기준:

### Q23: "그 약국 몇 시에 닫아?"
- **기존 라벨**: `unsupported`
- **재감사 결과**: `place_info`
- **이유**: 장소의 영업 마감 시각을 묻는 질문은 명백히 장소의 속성 정보(`place_info`)입니다. 기존에 `unsupported`로 분류된 것은 초기 프롬프트/평가 간 라벨 드리프트로 인한 오류입니다.

### Q13: "버스 하나 놓쳤어"
- **기존 라벨**: `running_late`
- **재감사 결과**: `running_late` (단, 지연 분이 없으므로 `needs_confirm` 또는 문맥 필요)
- **분석**: "버스 하나 놓쳤어"는 상황 서술이며 몇 분 늦을지 명시되지 않았습니다. 규칙 엔진 및 LLM 정책에서는 이를 `running_late`로 보되, `delay_minutes` 누락으로 `needs_confirm` 되묻기("몇 분 늦을 것 같아요?")를 수행합니다.

### Q25: "약 안 사도 되니까 편의점만 들를게"
- **기존 라벨**: `change_todo|stopover_check`
- **재감사 결과**: `change_todo|stopover_check` (다중 의도 유지)
- **이유**: "약 안 사도 되니까"(`change_todo: delete`), "편의점만 들를게"(`stopover_check`). 두 의도가 명확히 결합된 복합 발화입니다.

---

## 3. 다중 의도(Multi-label) 규칙

- 한 발화에 2개 이상의 독립된 요구가 포함된 경우 `|` 로 결합 (예: `running_late|stopover_check`).
- 1차 구현에서는 최대 2개 의도까지만 허용합니다 (데이터상 3개 조합 발화 없음).
- confusable 쌍(예: `next_vehicle` + `time_left`)은 둘 다 `tau_multi`를 충족하지 못하면 `abstained:conflict`로 처리하여 안전하게 LLM에 위임합니다.

---

## 4. 데이터셋 분할 및 금기 원칙

1. **`questions_v2.csv` (Gold Test)**:
   - 사람에 의해 엄격히 감사된 최종 평가용 데이터셋입니다.
   - **임계값 튜닝이나 예시 선택에 절대 사용하지 않습니다.**
2. **`validation.csv`**:
   - 의도별 임계값(`tau_accept`, `tau_multi`) 및 Top-m 파라미터($m \in \{1, 2, 3\}$)를 선택하기 위한 전용 데이터셋입니다.
3. **`vector_examples.csv`**:
   - 벡터 임베딩 인덱스 구성을 위한 예시 데이터셋입니다. 7개 의도만 포함하며, `unsupported`는 포함하지 않습니다.
4. **그룹 분할 (`group_id`)**:
   - 유사한 패러프레이즈나 어휘 변형은 반드시 동일한 `group_id`로 묶어 split 간 데이터 누수를 방지합니다.
