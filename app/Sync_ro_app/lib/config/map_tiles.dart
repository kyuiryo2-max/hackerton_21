import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

/// 지도 바탕 그림 (#51 피드백 6: 카카오·네이버처럼 단순하게).
///
/// CARTO "Voyager"는 OpenStreetMap 기본 지도보다 글자·색이 적어 경로 선이 잘 보여요.
/// CARTO는 무료 키가 필요해서 (비상업 월 500만 건까지 무료), 빌드할 때 키를 넣었을 때만 써요.
///   flutter run --dart-define=CARTO_BASEMAP_KEY=키
/// 키가 없으면 지금처럼 OpenStreetMap 기본 지도를 써요.
/// 두 지도 모두 출처 표시가 조건이라 지우면 안 돼요.
class MapTiles {
  MapTiles._();

  static const String _cartoKey = String.fromEnvironment('CARTO_BASEMAP_KEY');

  /// 단순한 지도(CARTO)를 쓰는지
  static bool get simple => _cartoKey.isNotEmpty;

  static String get urlTemplate => simple
      ? 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png?key=$_cartoKey'
      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// 지도 출처 (화면에 꼭 보여야 해요)
  static List<String> get credits =>
      simple ? const ['OpenStreetMap contributors', 'CARTO'] : const ['OpenStreetMap contributors'];

  static String get creditText => credits.map((c) => '© $c').join(' · ');

  static TileLayer layer() => TileLayer(
        urlTemplate: urlTemplate,
        userAgentPackageName: 'com.syncro.sync_ro_app',
        maxNativeZoom: 18,
      );

  static Widget attribution() => RichAttributionWidget(
        attributions: [for (final c in credits) TextSourceAttribution(c)],
      );
}
