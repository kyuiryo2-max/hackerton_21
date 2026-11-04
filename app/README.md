# app (Flutter 웹)

이 폴더는 아직 비어 있어요. 앱 담당이 처음 한 번만 아래 명령으로 Flutter 프로젝트를 만들어 주세요.

```bash
flutter --version          # 3.35.7 인지 확인
cd app
flutter create --project-name teumgil --platforms web,android .
flutter run -d chrome
```

- `pubspec.lock` 은 커밋해서 팀 전원이 같은 패키지 버전을 쓰게 해요.
- 지도·음성 패키지는 **웹 지원 여부를 확인한 뒤** 추가해요.
- 서버 주소는 코드에 직접 쓰지 말고 `--dart-define=API_BASE_URL=...` 로 넘겨요.
