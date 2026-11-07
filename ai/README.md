# AI 모듈 및 테스트 파이프라인 (`ai/`)

팀 Sync-ro 확정 규격(`docs/design/json-format.md`)에 맞춘 AI 파이프라인 및 정답률 평가 도구입니다.

---

## 1. 디렉터리 구성

```
ai/
├── pipeline.py             # 확정 규격 AI 파이프라인 (Mock/LLM 파서, 스키마 검증, 시간/경로 계산 엔진)
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

### 파이프라인 데모 실행 (더미 모드)
API 키 없이도 8대 의도 및 가용 시간, 출발 시각, 체류 여부 역산 검증을 즉시 실행합니다:
```bash
python ai/pipeline.py --demo
```

### 단일 문장 테스트
```bash
python ai/pipeline.py "편의점 들렀다 가도 돼?"
python ai/pipeline.py "약 사기"
```

### 40개 테스트 케이스 정답률 평가
```bash
# server 폴더 기준
uv run python ../ai/eval/run.py --prompt v1
```
