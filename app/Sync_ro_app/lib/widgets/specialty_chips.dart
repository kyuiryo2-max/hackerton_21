import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// 병원 할 일인데 진료과가 없으면 칩으로 물어봐요 (11/13).
/// 고른 진료과를 할 일 이름 뒤에 붙이면("병원 가기 (피부과)") 서버가 그 진료과만 찾아요.
/// 서버 places.SPECIALTIES 와 같은 말을 써요.
const List<String> kSpecialties = [
  '내과', '피부과', '치과', '정형외과', '이비인후과', '안과', '정신건강의학과',
  '소아청소년과', '산부인과', '비뇨의학과', '신경과', '가정의학과', '한의원',
];

/// 할 일 이름에 이미 진료과가 있는지 볼 때 쓰는 말 (줄임말 포함)
const List<String> _specialtyWords = [
  ...kSpecialties, '정신과', '소아과', '비뇨기과', '신경외과', '성형외과', '외과',
];

/// 병원 할 일인데 이름에 진료과가 없으면 true
bool needsSpecialty(String title, Iterable<String> placeTypes) =>
    placeTypes.contains('병원') && !_specialtyWords.any(title.contains);

/// 진료과 붙인 새 이름: "병원 가기" + "피부과" → "병원 가기 (피부과)"
String withSpecialty(String title, String specialty) => '$title ($specialty)';

/// 진료과를 고르는 칩. 고르면 그 진료과, "상관없어요"면 빈 문자열, 그냥 닫으면 null
Future<String?> askSpecialty(BuildContext context, String todoTitle) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('어느 진료과에 가요?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('"$todoTitle" · 진료과를 알면 그 병원만 찾아 드려요.',
              style: const TextStyle(color: AppTheme.textMuted)),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final s in kSpecialties)
              ActionChip(label: Text(s), onPressed: () => Navigator.pop(sheet, s)),
          ]),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => Navigator.pop(sheet, ''),
              child: const Text('상관없어요 (병원 전체)'),
            ),
          ),
        ]),
      ),
    ),
  );
}
