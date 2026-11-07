
import '../models/schedule.dart';

final List<Schedule> mockSchedules = [
  Schedule(
    id: 1,
    title: '학교 수업',
    location: '대학교',
    startTime: DateTime(2026, 11, 6, 9, 0),
    endTime: DateTime(2026, 11, 6, 10, 30),
  ),
  Schedule(
    id: 2,
    title: '팀 프로젝트 회의',
    location: '스터디룸',
    startTime: DateTime(2026, 11, 6, 13, 0),
    endTime: DateTime(2026, 11, 6, 15, 0),
  ),
  Schedule(
    id: 3,
    title: '도서관 공부',
    location: '중앙도서관',
    startTime: DateTime(2026, 11, 6, 17, 0),
    endTime: DateTime(2026, 11, 6, 19, 0),
  ),
];
