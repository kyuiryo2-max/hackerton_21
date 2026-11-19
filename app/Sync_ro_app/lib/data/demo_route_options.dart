import 'package:latlong2/latlong.dart';

/// Bundled Kakao sample routes. These are demonstration-only, not live directions.
class DemoRouteOption {
  final String label;
  final int durationSeconds;
  final int fare;
  final int transfers;
  final List<DemoRouteLeg> legs;
  const DemoRouteOption(this.label, this.durationSeconds, this.fare, this.transfers, this.legs);
}

class DemoRouteLeg {
  final String mode;
  final String label;
  final int seconds;
  final List<LatLng> path;
  const DemoRouteLeg(this.mode, this.label, this.seconds, this.path);
}
