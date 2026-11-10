import 'package:flutter/material.dart';

import 'demo_route_options.dart';

/// Route-specific colors for the bundled transit demo.
/// Subway colors follow the conventional Seoul metropolitan line palette.
class DemoRouteStyle {
  static const Color bus = Color(0xFF087F8C); // Teal, separate from subway lines.
  static const Color walking = Color(0xFF858B93);

  static const Map<int, Color> subwayColors = <int, Color>{
    1: Color(0xFF0052A4),
    2: Color(0xFF00A84D),
    3: Color(0xFFEF7C1C),
    4: Color(0xFF00A5DE),
    5: Color(0xFF996CAC),
    6: Color(0xFFCD7C2F),
    7: Color(0xFF747F00),
    8: Color(0xFFE6186C),
    9: Color(0xFFBDB092),
  };

  static int? subwayNumber(String label) {
    final match = RegExp(r'(\d+)호선').firstMatch(label);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  static Color colorFor(String mode, String label) {
    if (mode == 'WALKING') return walking;
    if (mode == 'BUS') return bus;
    if (mode == 'SUBWAY') {
      return subwayColors[subwayNumber(label)] ?? const Color(0xFF7059AD);
    }
    return walking;
  }

  static IconData iconFor(String mode) {
    switch (mode) {
      case 'BUS': return Icons.directions_bus;
      case 'SUBWAY': return Icons.train;
      default: return Icons.directions_walk;
    }
  }

  static String nameFor(DemoRouteLeg leg) {
    if (leg.mode == 'WALKING') return '도보 환승';
    if (leg.mode == 'SUBWAY') {
      final number = subwayNumber(leg.label);
      return number == null ? '지하철' : '$number호선';
    }
    final m = RegExp(r'\b(\d{3,4})\b').firstMatch(leg.label);
    return m == null ? '버스' : '${m.group(1)}번 버스';
  }

  /// Sample text uses `name (origin > destination)`; keep nested parentheses
  /// in station names (e.g. 안암(고대병원앞)) intact.
  static (String, String) endpoints(DemoRouteLeg leg) {
    if (leg.mode == 'WALKING') {
      // The sample identifies a transfer at Dongmyo; it does not supply
      // platform-level names, so show the known interchange endpoints only.
      if (leg.label.contains('동묘앞')) return ('동묘앞역 · 6호선', '동묘앞역 · 1호선');
      return ('환승 시작', '환승 완료');
    }
    final from = leg.label.indexOf('(');
    final to = leg.label.lastIndexOf(')');
    if (from >= 0 && to > from) {
      final inner = leg.label.substring(from + 1, to);
      final parts = inner.split(' > ');
      if (parts.length == 2) return (parts.first.trim(), parts.last.trim());
    }
    return ('구간 시작', '구간 종료');
  }
}
