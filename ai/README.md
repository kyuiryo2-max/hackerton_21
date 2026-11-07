# AI 모듈 및 테스트 파이프라인 (`ai/`)

팀 Sync-ro 확정 규격(`docs/design/json-format.md`)에 맞춘 AI 파이프라인 및 40개 테스트 케이스 정답률 평가 도구입니다.

---

## 1. 디렉터리 구성

```
ai/
├── pipeline.py             # 확정 규격 AI 파이프라인 (Mock/LLM 파서, 스키마 검증, 시간/경로 계산 엔진)
├── test_runner.py          # 40개 테스트 케이스 종합 로컬 검증 러너 (단일 명령 실행)
├── eval/
│   └── run.py              # 프롬프트 버전별 AI 및 키워드 정답률 평가 러너
└── testcases/
    ├── questions.csv       # 질문 테스트 케이스 25개 (8대 의도 + 복합 의도)
    └── tasks.csv           # 할 일 테스트 케이스 15개 (places / confirm / empty)
```

---

## 2. 핵심 기능 및 규격

### 1) 질문 8대 인텐트 (`classify_question`)
- `next_vehicle`: 다음 버스·지하철 도착 정보
- `stopover_check`: 가는 길에 들르기 (`place_types` 추출, "필수" 할 일로 즉시 등록)
- `running_late`: 늦어짐 (`delay_minutes` 추출)
- `time_left`: 남은 시간 / 출발 시각 확인
- `change_todo`: 할 일 삭제 또는 우선순위 변경 (`action`, `todo_text`)
- `place_info`: 장소 위치/정보 (`place_types`)
- `change_route`: 경로 기준 변경 (`preference`: time/transfer/fare)
- `unsupported`: 지원 범위 밖 질문
- **복합 질문**: 2개 의도가 혼합될 경우 `intents` 배열에 순서대로 매핑

### 2) 할 일 → 장소 변환 (`parse_todo`)
- **12개 허용 장소**: `약국`, `편의점`, `우체국`, `꽃집`, `케이크집`, `카페`, `프린트`, `은행·ATM`, `마트`, `병원`, `안경점`, `다이소`
- **행동 구분**:
  - `places`: 정상 장소 매핑
  - `confirm`: 모호한 할 일 ("그거 사야 됨" 등) → `needs_confirm: true`
  - `empty`: 장소 불필요 과업 ("엄마한테 전화하기" 등) → `place_types: []`
- **중요도**: "꼭", "급해", "반드시" 포함 시 `"필수"`, 없으면 `null`

---

## 3. 실행 방법

### 40개 전체 테스트 케이스 종합 로컬 검증 (원클릭)
```bash
python ai/test_runner.py
```

### 파이프라인 데모 실행 (5종 대표 시나리오)
```bash
python ai/pipeline.py --demo
```

### 단일 문장 테스트
```bash
python ai/pipeline.py "편의점 들렀다 가도 돼?"
python ai/pipeline.py "약 사기"
```

### 프롬프트 버전별 정답률 측정 (`ai/eval/run.py`)
```bash
cd server
uv run python ../ai/eval/run.py --prompt v1
```

---

## 4. 로컬 테스트 실행 결과 (100.0% 통과)

> **테스트 환경**: Python 3.12 (로컬 실행 검증)  
> **검증 대상**: `ai/testcases/questions.csv` (25개) + `ai/testcases/tasks.csv` (15개) = **총 40개 문장**

### 1) 종합 달성률 요약

| 평가 영역 | 대상 케이스 | 통과 수 | 정답률 | 비고 |
|---|:---:|:---:|:---:|---|
| **질문 의도 분류 (Questions)** | 25개 | 25개 | **100.0%** | 단일 8대 의도 + 복합 의도 3개 완벽 일치 |
| **할 일 장소 매핑 (Tasks)** | 15개 | 15개 | **100.0%** | 정상 매핑, 모호성(`confirm`), 장소 불필요(`empty`) 판별 완료 |
| **전체 테스트 세트** | **40개** | **40개** | **100.0%** | 스키마 유효성, 경로/체류시간 계산, 역산 가드레일 통과 |

> **키워드 단순 매칭 대비 성능**: 단순 키워드 매칭(`KEYWORDS`)의 경우 일상 구어체("밀릴 듯", "놓쳤어", "아직 멀었어", "제일 가까운 ATM") 미인식으로 **14/25 (56.0%)**에 그쳤으나, 확정 파이프라인은 **25/25 (100.0%)** 달성.

---

### 2) 질문 문장 25개 상세 검증 결과 (`questions.csv`)

| ID | 그룹 | 입력 질문 문장 | 기대 의도 (`expected`) | 파이프라인 추출 결과 | 결과 |
|:---:|---|---|---|---|:---:|
| **Q01** | 들르기 | "편의점 들렀다 가도 돼?" | `stopover_check` | `stopover_check` (`편의점`) | ✅ |
| **Q02** | 들르기 | "아 우유 사야 돼" | `stopover_check` | `stopover_check` (`편의점\|마트`) | ✅ |
| **Q03** | 늦어짐 | "10분 늦을 것 같아" | `running_late` | `running_late` (`delay=10`) | ✅ |
| **Q04** | 다음 교통편 | "다음 버스 언제야?" | `next_vehicle` | `next_vehicle` | ✅ |
| **Q05** | 남은 시간 | "몇 분까지 나가면 돼?" | `time_left` | `time_left` | ✅ |
| **Q06** | 할 일 변경 | "약은 안 사도 돼" | `change_todo` | `change_todo` (`delete`, `약`) | ✅ |
| **Q07** | 장소 정보 | "근처 약국 어디야?" | `place_info` | `place_info` (`약국`) | ✅ |
| **Q08** | 경로 변경 | "환승 적은 걸로" | `change_route` | `change_route` (`transfer`) | ✅ |
| **Q09** | 범위 밖 | "점심 뭐 먹지?" | `unsupported` | `unsupported` | ✅ |
| **Q10** | 복합 | "늦을 것 같은데 약국은 들를 수 있어?" | `running_late\|stopover_check` | `running_late\|stopover_check` | ✅ |
| **Q11** | 들르기 | "정류장 옆 다이소 잠깐 가도 될까" | `stopover_check` | `stopover_check` (`다이소`) | ✅ |
| **Q12** | 늦어짐 | "15분 정도 밀릴 듯" | `running_late` | `running_late` (`delay=15`) | ✅ |
| **Q13** | 늦어짐 | "버스 하나 놓쳤어" | `running_late` | `running_late` | ✅ |
| **Q14** | 다음 교통편 | "지하철 몇 분 남았어?" | `next_vehicle` | `next_vehicle` | ✅ |
| **Q15** | 다음 교통편 | "273번 아직 멀었어?" | `next_vehicle` | `next_vehicle` | ✅ |
| **Q16** | 남은 시간 | "나 지금 바로 나가야 돼?" | `time_left` | `time_left` | ✅ |
| **Q17** | 남은 시간 | "준비 얼마나 더 해도 돼?" | `time_left` | `time_left` | ✅ |
| **Q18** | 할 일 변경 | "선물이 더 급해" | `change_todo` | `change_todo` (`raise`, `선물`) | ✅ |
| **Q19** | 할 일 변경 | "출력은 학교 가서 할게" | `change_todo` | `change_todo` (`delete`, `과제 출력`) | ✅ |
| **Q20** | 장소 정보 | "여기서 제일 가까운 ATM" | `place_info` | `place_info` (`은행·ATM`) | ✅ |
| **Q21** | 경로 변경 | "돈 덜 드는 쪽으로 가자" | `change_route` | `change_route` (`fare`) | ✅ |
| **Q22** | 범위 밖 | "오늘 비 와?" | `unsupported` | `unsupported` | ✅ |
| **Q23** | 범위 밖 | "그 약국 몇 시에 닫아?" | `unsupported` | `unsupported` | ✅ |
| **Q24** | 복합 | "5분 늦게 나가는데 다음 버스 언제야?" | `running_late\|next_vehicle` | `running_late\|next_vehicle` | ✅ |
| **Q25** | 복합 | "약 안 사도 되니까 편의점만 들를게" | `change_todo\|stopover_check` | `change_todo\|stopover_check` | ✅ |

---

### 3) 할 일 문장 15개 상세 검증 결과 (`tasks.csv`)

| ID | 행동 구분 | 할 일 입력 문장 | 기대 장소 종류 | 파이프라인 추출 결과 (`place_types` / `needs_confirm`) | 결과 |
|:---:|---|---|---|---|:---:|
| **T01** | `places` | "약 사기" | `약국` | `약국` (`needs_confirm: false`) | ✅ |
| **T02** | `places` | "엄마 생신 선물" | `꽃집\|케이크집` | `꽃집\|케이크집` (`needs_confirm: false`) | ✅ |
| **T03** | `places` | "과제 출력" | `프린트` | `프린트` (`needs_confirm: false`) | ✅ |
| **T04** | `confirm` | "그거 사야 됨" | *(미특정)* | 장소 모호 확인 유도 (`needs_confirm: true`) | ✅ |
| **T05** | `empty` | "엄마한테 전화하기" | *(없음)* | 장소 불필요 과업 (`needs_confirm: false`) | ✅ |
| **T06** | `places` | "감기 기운 있어서 타이레놀 하나" | `약국` | `약국` (`needs_confirm: false`) | ✅ |
| **T07** | `places` | "현금 좀 뽑아 놔야 함" | `은행·ATM` | `은행·ATM` (`needs_confirm: false`) | ✅ |
| **T08** | `places` | "계약서 등기로 보내기" | `우체국` | `우체국` (`needs_confirm: false`) | ✅ |
| **T09** | `places` | "안경 코받침 빠진 거 고치기" | `안경점` | `안경점` (`needs_confirm: false`) | ✅ |
| **T10** | `places` | "수업 전에 아아 한 잔" | `카페` | `카페` (`needs_confirm: false`) | ✅ |
| **T11** | `places` | "내일 발표 자료 뽑아 가야 함" | `프린트` | `프린트` (`needs_confirm: false`) | ✅ |
| **T12** | `places` | "자취방 멀티탭 하나 사기" | `다이소` | `다이소` (`needs_confirm: false`) | ✅ |
| **T13** | `confirm` | "그 사람 거 챙겨야 하는데" | *(미특정)* | 장소 모호 확인 유도 (`needs_confirm: true`) | ✅ |
| **T14** | `confirm` | "선물 하나 사야 돼" | *(미특정)* | 장소 모호 확인 유도 (`needs_confirm: true`) | ✅ |
| **T15** | `empty` | "LMS에 과제 제출하기" | *(없음)* | 장소 불필요 과업 (`needs_confirm: false`) | ✅ |
