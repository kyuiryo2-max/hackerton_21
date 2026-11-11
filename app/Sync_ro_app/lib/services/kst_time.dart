/// Korea Standard Time display helper for server timestamps with UTC or offsets.
class KstTime {
  static DateTime? parse(dynamic raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw.toString());
  }
  static DateTime toKst(DateTime date) => date.toUtc().add(const Duration(hours: 9));
  static String hm(DateTime? date) {
    if (date == null) return '정보 없음';
    final d = toKst(date);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}
