Sync_ro 오프라인 샘플 경로 테스트

1. PowerShell에서 이 폴더로 이동
2. python .\sample_server.py
3. 다른 PowerShell에서 Invoke-RestMethod http://127.0.0.1:8000/health
4. Flutter 프로젝트에서 --dart-define=SYNC_RO_USE_REAL_API=true --dart-define=SYNC_RO_API_URL=http://127.0.0.1:8000 으로 실행

주의: 이 서버는 samples/kakao_publictraffic.json의 2026-11-05 고정 경로 15개만 반환합니다.
출발지, 목적지, 희망 도착시간을 기준으로 재검색하지 않습니다.
실제 카카오 키 및 인터넷 접속 불필요. 운영 환경에서 사용하지 마세요.
