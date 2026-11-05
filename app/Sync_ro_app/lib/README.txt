Sync_ro Flutter UI starter

구성
- lib/main.dart
- lib/screens/home_screen.dart
- lib/screens/route_screen.dart
- lib/widgets/section_card.dart
- lib/widgets/app_bottom_nav.dart

적용 방법
1. 압축을 풉니다.
2. 기존 Flutter 프로젝트의 lib 폴더를 백업합니다.
3. 압축 안의 lib 폴더 내용을 프로젝트의 lib 폴더에 복사합니다.
4. 프로젝트 루트(pubspec.yaml이 있는 폴더)에서 터미널을 엽니다.
5. flutter pub get
6. flutter run

참고
- 외부 패키지 없이 Flutter 기본 Material 위젯만 사용합니다.
- 지도는 현재 디자인 확인용 임시 지도입니다. 실제 지도 API가 연결된 것은 아닙니다.
- GPS, 교통 API, 음성 인식, AI 추천 기능은 아직 연결하지 않았습니다.
- 화면에 표시된 시간/요금/버스 정보는 예시 데이터입니다.
