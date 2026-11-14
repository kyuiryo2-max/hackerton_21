/// AI 질문 화면에서 "일정 추가해 줘" 문장을 일정 초안으로 바꿔요.
///
/// 1순위: 서버 /api/ask 가 `result.intent == "add_schedule"` 과 `result.schedule` 을 주면 그 값을 써요.
/// 2순위(임시): 서버가 아직 이 질문 종류를 모르면(`unsupported`) 앱이 문장에서 날짜·시각·장소를 대략 읽어요.
///   이 값은 바로 저장하지 않고, 항상 일정 입력 화면에 채워서 사용자가 확인한 뒤 저장해요.
class ScheduleDraft {
  const ScheduleDraft({
    required this.title,
    required this.location,
    required this.start,
    this.end,
    required this.fromServer,
    this.timeGuessed = false,
  });

  final String title;
  final String location;
  final DateTime start;
  final DateTime? end;
  final bool fromServer;
  /// 시각을 문장에서 못 찾아 기본값을 넣었어요
  final bool timeGuessed;

  /// 서버 응답 result → 초안. 모양: {"intent":"add_schedule","schedule":{"title","location","start_time","end_time"}}
  /// 서버는 일정 이름·목적지만 주고 날짜·시각은 안 줄 수 있어요. 그때는 한 시간 뒤를 기본값으로 채우고
  /// timeGuessed=true 로 표시해서 화면에서 사용자가 바꾸게 해요.
  static ScheduleDraft? fromServerResult(Map<String, dynamic>? result) {
    if (result == null || result['intent'] != 'add_schedule') return null;
    final raw = result['schedule'];
    if (raw is! Map) return null;
    return fromScheduleMap(raw);
  }

  /// 일정 초안 맵 {"title","location"} → 일정 입력 화면용. 시각이 없어도 돼요.
  static ScheduleDraft? fromScheduleMap(Map<dynamic, dynamic> raw) {
    final start = DateTime.tryParse('${raw['start_time'] ?? raw['arrive_by'] ?? ''}');
    final guessed = start == null;
    final base = (start ?? DateTime.now().add(const Duration(hours: 1))).toLocal();
    return ScheduleDraft(
      title: '${raw['title'] ?? '새 일정'}',
      location: '${raw['location'] ?? raw['place_name'] ?? ''}',
      start: base,
      end: DateTime.tryParse('${raw['end_time'] ?? ''}')?.toLocal(),
      fromServer: true,
      timeGuessed: guessed,
    );
  }

  static final _trigger = RegExp(r'(일정|약속|스케줄|예약).{0,6}(추가|넣어|등록|잡아|만들어|저장)|(추가|등록)해\s*줘.*일정');
  static final _timeRe = RegExp(r'(오전|오후|아침|낮|저녁|밤)?\s*(\d{1,2})\s*시\s*(?:(\d{1,2})\s*분|(반))?');
  static final _clockRe = RegExp(r'\b(\d{1,2}):(\d{2})\b');
  static final _monthDayRe = RegExp(r'(\d{1,2})\s*월\s*(\d{1,2})\s*일');
  static final _dayOnlyRe = RegExp(r'(?<!월\s?)(\d{1,2})\s*일(?!정)');
  static final _weekdayRe = RegExp(r'(다음\s*주\s*)?([월화수목금토일])요일');
  static final _placeRe = RegExp(r'([가-힣A-Za-z0-9]{2,}?)(?:에서|으로|에|로)(?=\s|$)');
  static final _purposeRe = RegExp(r'([가-힣A-Za-z0-9]{1,12}?)\s*(보러|하러|먹으러|받으러|만나러|들으러)');

  static const _dayWords = {'오늘': 0, '내일': 1, '모레': 2, '글피': 3};
  static const _notPlace = {'오늘', '내일', '모레', '글피', '아침', '저녁', '오전', '오후', '밤', '낮', '일정', '다음주', '이번주'};

  /// 서버가 일정 추가를 지원하기 전까지 쓰는 간단한 해석. 일정 추가 문장이 아니면 null.
  static ScheduleDraft? parseLocal(String text, DateTime now) {
    final t = text.trim();
    if (!_trigger.hasMatch(t)) return null;

    // 날짜
    var day = DateTime(now.year, now.month, now.day);
    var dayFound = false;
    for (final e in _dayWords.entries) {
      if (t.contains(e.key)) {
        day = day.add(Duration(days: e.value));
        dayFound = true;
        break;
      }
    }
    if (!dayFound) {
      final md = _monthDayRe.firstMatch(t);
      final wd = _weekdayRe.firstMatch(t);
      final d = _dayOnlyRe.firstMatch(t);
      if (md != null) {
        var y = now.year;
        final m = int.parse(md.group(1)!), dd = int.parse(md.group(2)!);
        if (DateTime(y, m, dd).isBefore(day)) y++;
        day = DateTime(y, m, dd);
        dayFound = true;
      } else if (wd != null) {
        final target = '월화수목금토일'.indexOf(wd.group(2)!) + 1;
        var diff = (target - now.weekday) % 7;
        if (wd.group(1) != null) diff += 7;
        if (diff == 0 && wd.group(1) == null) diff = 0;
        day = day.add(Duration(days: diff));
        dayFound = true;
      } else if (d != null) {
        final dd = int.parse(d.group(1)!);
        var candidate = DateTime(now.year, now.month, dd);
        if (candidate.isBefore(day)) candidate = DateTime(now.year, now.month + 1, dd);
        day = candidate;
        dayFound = true;
      }
    }

    // 시각
    var hour = -1, minute = 0;
    final tm = _timeRe.firstMatch(t);
    final cm = _clockRe.firstMatch(t);
    if (tm != null) {
      hour = int.parse(tm.group(2)!);
      minute = tm.group(3) != null ? int.parse(tm.group(3)!) : (tm.group(4) != null ? 30 : 0);
      final period = tm.group(1);
      final pm = period == '오후' || period == '저녁' || period == '밤' || (period == '낮' && hour < 6);
      if (pm && hour < 12) hour += 12;
      if (period == null && hour >= 1 && hour <= 6) hour += 12; // "3시" → 보통 오후 3시
    } else if (cm != null) {
      hour = int.parse(cm.group(1)!);
      minute = int.parse(cm.group(2)!);
    }
    final guessed = hour < 0 || hour > 23 || minute > 59;
    if (guessed) {
      hour = 9;
      minute = 0;
    }
    var start = DateTime(day.year, day.month, day.day, hour, minute);
    if (!dayFound && start.isBefore(now)) start = start.add(const Duration(days: 1));

    // 장소
    var location = '';
    for (final m in _placeRe.allMatches(t)) {
      final word = m.group(1)!;
      if (_notPlace.contains(word) || RegExp(r'\d').hasMatch(word) && RegExp(r'(시|분|일|월)$').hasMatch(word)) continue;
      if (RegExp(r'^\d+$').hasMatch(word)) continue;
      location = word;
      break;
    }

    // 제목: "시험보러" → 시험, 없으면 장소 이름
    final purpose = _purposeRe.firstMatch(t);
    var title = purpose?.group(1)?.trim() ?? '';
    if (title.isEmpty || _notPlace.contains(title) || title == location) {
      title = location.isEmpty ? '새 일정' : '$location 일정';
    }

    return ScheduleDraft(
      title: title,
      location: location,
      start: start,
      fromServer: false,
      timeGuessed: guessed,
    );
  }
}
