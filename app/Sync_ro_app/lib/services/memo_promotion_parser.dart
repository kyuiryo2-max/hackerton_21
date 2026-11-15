/// 메모 한 줄을 기존 '일정 추가' 폼의 초기값으로 바꿔요.
///
/// 저장을 대신하지 않고, 사용자가 일정 폼에서 장소·시각을 확인한 뒤 저장하게
/// 제목·장소·반복 요일만 미리 채우는 역할이에요.
class MemoPromotionDraft {
  const MemoPromotionDraft({
    required this.title,
    required this.location,
    required this.start,
    this.repeatWeekly = false,
    this.placeType,
  });

  final String title;
  final String location;
  final DateTime start;
  final bool repeatWeekly;

  /// 할 일 폼에서 미리 골라 둘 장소 종류 (없으면 자동 분류).
  final String? placeType;
}

class MemoPromotionParser {
  MemoPromotionParser._();

  static const Map<String, int> _weekdays = {
    '월': 1,
    '화': 2,
    '수': 3,
    '목': 4,
    '금': 5,
    '토': 6,
    '일': 7,
  };

  static const Map<String, int> _dayWords = {
    '오늘': 0,
    '내일': 1,
    '모레': 2,
    '글피': 3,
  };

  static final RegExp _weekdayRe = RegExp(
    r'(매주\s*)?(?<![\d내모글])(월|화|수|목|금|토|일)(?:요일|(?=\s)|$)',
  );
  static final RegExp _timeRe = RegExp(
    r'(오전|오후|아침|점심|저녁|밤|낮)?\s*(\d{1,2})\s*시\s*(?:(\d{1,2})\s*분|(반))?',
  );
  static final RegExp _clockRe = RegExp(r'(\d{1,2}):(\d{2})');
  static final RegExp _monthDayRe = RegExp(r'(\d{1,2})\s*월\s*(\d{1,2})\s*일');
  static final RegExp _dayOnlyRe = RegExp(r'(?<!월\s?)(\d{1,2})\s*일(?!정)');
  static final RegExp _locationRe = RegExp(
    r'([가-힣A-Za-z0-9]{0,20}?(?:교회|성당|병원|치과|학교|회사|공항|터미널|역|카페|마트|약국|은행|우체국|공원|도서관|영화관|식당|음식점|센터|클리닉|매장|지점|아파트|빌딩))',
  );

  /// "매주 일요일 교회" → 다음 일요일 09:00, 매주 반복, 장소 교회.
  /// "내일 오후 3시 치과 예약" → 내일 15:00, 일회성, 장소 치과.
  static MemoPromotionDraft forSchedule(String rawText, {DateTime? now}) {
    final text = rawText.trim();
    final base = now ?? DateTime.now();
    final today = DateTime(base.year, base.month, base.day);

    int? weekday;
    var repeatWeekly = false;
    final weekdayMatch = _weekdayRe.firstMatch(text);
    if (weekdayMatch != null) {
      weekday = _weekdays[weekdayMatch.group(2)];
      repeatWeekly = weekdayMatch.group(1) != null;
    }

    DateTime? day;
    for (final entry in _dayWords.entries) {
      if (text.contains(entry.key)) {
        day = today.add(Duration(days: entry.value));
        break;
      }
    }
    if (day == null) {
      final monthDay = _monthDayRe.firstMatch(text);
      if (monthDay != null) {
        final month = int.parse(monthDay.group(1)!);
        final date = int.parse(monthDay.group(2)!);
        var candidate = DateTime(today.year, month, date);
        if (candidate.isBefore(today)) {
          candidate = DateTime(today.year + 1, month, date);
        }
        day = candidate;
      }
    }
    if (day == null) {
      final dayOnly = _dayOnlyRe.firstMatch(text);
      if (dayOnly != null) {
        final date = int.parse(dayOnly.group(1)!);
        var candidate = DateTime(today.year, today.month, date);
        if (candidate.isBefore(today)) {
          candidate = DateTime(today.year, today.month + 1, date);
        }
        day = candidate;
      }
    }

    var hour = 9;
    var minute = 0;
    var timeFound = false;
    final timeMatch = _timeRe.firstMatch(text);
    final clockMatch = _clockRe.firstMatch(text);
    if (timeMatch != null) {
      hour = int.parse(timeMatch.group(2)!);
      minute = timeMatch.group(3) != null
          ? int.parse(timeMatch.group(3)!)
          : (timeMatch.group(4) != null ? 30 : 0);
      final period = timeMatch.group(1);
      final isPm =
          period == '오후' ||
          period == '저녁' ||
          period == '밤' ||
          (period == '낮' && hour < 6);
      if (isPm && hour < 12) hour += 12;
      // "3시"처럼 오전·오후가 없으면 보통 오후로 읽어요.
      if (period == null && hour >= 1 && hour <= 6) hour += 12;
      timeFound = true;
    } else if (clockMatch != null) {
      hour = int.parse(clockMatch.group(1)!);
      minute = int.parse(clockMatch.group(2)!);
      timeFound = true;
    }

    DateTime start;
    if (weekday != null) {
      var diff = (weekday - today.weekday) % 7;
      if (diff == 0) {
        final candidate = DateTime(
          today.year,
          today.month,
          today.day,
          hour,
          minute,
        );
        if (!candidate.isAfter(base)) diff = 7;
      }
      start = today
          .add(Duration(days: diff))
          .add(Duration(hours: hour, minutes: minute));
    } else if (day != null) {
      start = DateTime(day.year, day.month, day.day, hour, minute);
      if (!start.isAfter(base)) start = start.add(const Duration(days: 1));
    } else if (timeFound) {
      start = DateTime(today.year, today.month, today.day, hour, minute);
      if (!start.isAfter(base)) start = start.add(const Duration(days: 1));
    } else {
      start = base.add(const Duration(hours: 1));
      start = DateTime(start.year, start.month, start.day, start.hour, 0);
    }

    final location = _locationRe.firstMatch(text)?.group(1)?.trim() ?? '';
    final cleaned = _cleanTitle(text);
    var title = cleaned;
    if (title.isEmpty) title = location.isEmpty ? '새 일정' : location;

    return MemoPromotionDraft(
      title: title,
      location: location,
      start: start,
      repeatWeekly: repeatWeekly,
    );
  }

  /// "약 사기" → 약국, "택배 부치기" → 우체국처럼 할 일 폼의 장소 종류를 미리 골라요.
  static String? todoPlaceType(String text) {
    const hints = <String, String>{
      '약 ': '약국',
      '약국': '약국',
      '처방': '약국',
      '택배': '우체국',
      '소포': '우체국',
      '커피': '카페',
      '꽃': '꽃집',
      '케이크': '케이크집',
      '은행': '은행·ATM',
      'ATM': '은행·ATM',
      '프린트': '프린트',
      '출력': '프린트',
      '안경': '안경점',
      '병원': '병원',
      '다이소': '다이소',
      '슬리퍼': '다이소',
      '실내화': '다이소',
      '양말': '다이소',
      '빵': '빵집',
      '화장품': '올리브영',
      '올리브영': '올리브영',
      '마트': '마트',
      '편의점': '편의점',
      '우유': '편의점',
      '음료': '편의점',
      '생수': '편의점',
      '콜라': '편의점',
      '주스': '편의점',
      '문구': '문구점',
      '볼펜': '문구점',
      '노트': '문구점',
      '물건': '편의점',
      '생필품': '마트',
    };
    for (final entry in hints.entries) {
      if (text.contains(entry.key)) return entry.value;
    }
    return null;
  }

  static String _cleanTitle(String text) {
    var cleaned = text;
    cleaned = cleaned.replaceAll(RegExp(r'매주'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'(월|화|수|목|금|토|일)요일'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'매주\s*(월|화|수|목|금|토|일)(?=\s|$)'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'(오늘|내일|모레|글피|이번\s*주|다음\s*주)'), ' ');
    cleaned = cleaned.replaceAll(
      RegExp(r'(오전|오후|아침|점심|저녁|밤|낮)?\s*\d{1,2}\s*시\s*(?:\d{1,2}\s*분|반)?'),
      ' ',
    );
    cleaned = cleaned.replaceAll(RegExp(r'\d{1,2}:\d{2}'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\d{1,2}\s*월\s*\d{1,2}\s*일'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'(?<!월\s?)\d{1,2}\s*일(?!정)'), ' ');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    cleaned = cleaned.replaceFirst(RegExp(r'^(에|에서|까지|부터)\s+'), '');
    return cleaned.trim();
  }
}
