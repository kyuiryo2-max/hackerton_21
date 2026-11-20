import '../models/place_recommendation.dart';

/// 메모·할 일 문장에서 "어디서 살 수 있는지"를 추천해요.
///
/// 서버 AI가 장소 종류를 붙여 주기 전에, 브랜드·카테고리 후보를 빠르게
/// 보여 주는 로컬 추천기예요. 실제 가장 가까운 지점은 기존
/// NearbyTodoService가 현재 위치와 장소 검색 결과로 다시 골라요.
class PlaceRecommendationService {
  const PlaceRecommendationService();

  /// 위치 권한을 묻기 전에 "구매할 물건을 찾는 문장"인지 가볍게 확인해요.
  /// 구체적인 물건만 적은 문장("고양이 사료")은 화면의 AI 버튼으로 요청해요.
  static bool looksLikePurchase(String rawText) {
    final text = rawText.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    return const [
      '사야',
      '사기',
      '사러',
      '사올',
      '사면',
      '구매',
      '장보기',
      '챙기',
      '필요',
    ].any(text.contains);
  }

  static const List<_Brand> _brands = [
    _Brand('스타벅스', '카페', '커피를 살 수 있는 카페예요.'),
    _Brand('메가커피', '카페', '커피를 살 수 있는 카페예요.'),
    _Brand('컴포즈커피', '카페', '커피를 살 수 있는 카페예요.'),
    _Brand('이디야', '카페', '커피를 살 수 있는 카페예요.'),
    _Brand('투썸플레이스', '카페', '커피를 살 수 있는 카페예요.'),
  ];

  static const List<_Rule> _rules = [
    _Rule(
      keywords: ['커피', '아메리카노', '라떼', '카푸치노', '에스프레소', '콜드브루', '모카', '카페'],
      places: [
        _Candidate('스타벅스', '카페'),
        _Candidate('메가커피', '카페'),
        _Candidate('컴포즈커피', '카페'),
      ],
      reason: '커피를 살 수 있는 카페예요.',
    ),
    _Rule(
      keywords: [
        '슬리퍼', '실내화', '신발', '양말', '생필품', '휴지', '세제', '수건', '칫솔', '치약',
        '이어폰', '헤드폰', '충전기', '케이블', '보조배터리',
      ],
      places: [
        _Candidate('다이소', '다이소'),
        _Candidate('편의점', '편의점'),
        _Candidate('문구점', '문구점'),
      ],
      reason: '생활용품을 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['음료', '음료수', '물', '생수', '콜라', '사이다', '주스', '이온음료', '제로콜라'],
      exclude: ['물건'],
      places: [
        _Candidate('편의점', '편의점'),
        _Candidate('마트', '마트'),
        _Candidate('카페', '카페'),
      ],
      reason: '음료를 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: [
        '문구',
        '볼펜',
        '펜',
        '노트',
        '공책',
        '다이어리',
        '가위',
        '풀',
        '테이프',
        '형광펜',
        '파일',
        '봉투',
      ],
      places: [
        _Candidate('문구점', '문구점'),
        _Candidate('다이소', '다이소'),
        _Candidate('편의점', '편의점'),
      ],
      reason: '문구류를 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['약국', '감기약', '소화제', '처방', '진통제', '반창고', '밴드', '약 '],
      exclude: ['약속', '계약'],
      places: [_Candidate('약국', '약국'), _Candidate('편의점', '편의점')],
      reason: '약이나 응급용품을 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['택배', '소포', '등기', '편지', '부치기'],
      places: [_Candidate('우체국', '우체국'), _Candidate('편의점', '편의점')],
      reason: '택배나 우편을 보낼 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['꽃', '꽃다발', '화분'],
      places: [_Candidate('꽃집', '꽃집'), _Candidate('마트', '마트')],
      reason: '꽃을 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['케이크', '디저트'],
      places: [
        _Candidate('케이크집', '케이크집'),
        _Candidate('빵집', '빵집'),
        _Candidate('편의점', '편의점'),
      ],
      reason: '케이크나 디저트를 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['빵', '베이커리'],
      places: [_Candidate('빵집', '빵집'), _Candidate('편의점', '편의점')],
      reason: '빵을 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['프린트', '출력', '복사', '스캔'],
      places: [_Candidate('프린트', '프린트'), _Candidate('편의점', '편의점')],
      reason: '프린트나 복사를 할 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['은행', 'atm', '현금', '송금', '입금', '출금'],
      places: [_Candidate('은행·ATM', '은행·ATM'), _Candidate('편의점', '편의점')],
      reason: '현금을 찾거나 송금할 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['화장품', '올리브영', '로션', '크림', '샴푸', '선크림', '세안'],
      places: [
        _Candidate('올리브영', '올리브영'),
        _Candidate('마트', '마트'),
        _Candidate('편의점', '편의점'),
      ],
      reason: '화장품이나 생활용품을 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['안경', '렌즈'],
      places: [_Candidate('안경점', '안경점'), _Candidate('마트', '마트')],
      reason: '안경이나 렌즈를 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['병원', '진료', '검진', '치과'],
      places: [_Candidate('병원', '병원'), _Candidate('약국', '약국')],
      reason: '진료를 받거나 약을 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: [
        '우유',
        '계란',
        '쌀',
        '과일',
        '채소',
        '고기',
        '라면',
        '과자',
        '간식',
        '장보기',
        '식료품',
      ],
      places: [_Candidate('마트', '마트'), _Candidate('편의점', '편의점')],
      reason: '식료품이나 간식을 살 수 있는 곳이에요.',
    ),
    _Rule(
      keywords: ['편의점', '도시락', '김밥', '삼각김밥', '간편식'],
      places: [_Candidate('편의점', '편의점'), _Candidate('마트', '마트')],
      reason: '간편하게 살 수 있는 곳이에요.',
    ),
    _Rule(
      // "사야 돼" 같은 구매 동사만으로는 어떤 물건인지 알 수 없어요.
      // 구체적인 물건을 찾지 못하면 화면이 서버 AI 추천으로 넘어가요.
      keywords: ['물건'],
      places: [
        _Candidate('편의점', '편의점'),
        _Candidate('마트', '마트'),
        _Candidate('다이소', '다이소'),
      ],
      reason: '가까운 편의점이나 마트에서 살 수 있어요.',
    ),
  ];

  /// [rawText]에 맞는 장소 후보를 최대 [limit]개 돌려줘요.
  /// 문장이 비어 있거나 살 수 있는 곳을 찾지 못하면 빈 목록이에요.
  List<PlaceRecommendation> recommend(String rawText, {int limit = 3}) {
    final text = rawText.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty || limit <= 0) return const [];

    final found = <String, PlaceRecommendation>{};

    void add(PlaceRecommendation recommendation) {
      final previous = found[recommendation.name];
      if (previous == null || recommendation.score < previous.score) {
        found[recommendation.name] = recommendation;
      }
    }

    // 사용자가 브랜드를 직접 말했으면 그 브랜드를 가장 먼저 보여 줘요.
    for (var i = 0; i < _brands.length; i++) {
      final brand = _brands[i];
      if (text.contains(brand.name.toLowerCase())) {
        add(
          PlaceRecommendation(
            name: brand.name,
            category: brand.category,
            reason: brand.reason,
            score: -100 + i,
          ),
        );
      }
    }

    for (var ruleIndex = 0; ruleIndex < _rules.length; ruleIndex++) {
      final rule = _rules[ruleIndex];
      if (!rule.matches(text)) continue;
      for (var placeIndex = 0; placeIndex < rule.places.length; placeIndex++) {
        final place = rule.places[placeIndex];
        add(
          PlaceRecommendation(
            name: place.name,
            category: place.category,
            reason: rule.reason,
            score: ruleIndex * 10 + placeIndex,
          ),
        );
      }
    }

    final result = found.values.toList()
      ..sort((a, b) {
        final score = a.score.compareTo(b.score);
        return score != 0 ? score : a.name.compareTo(b.name);
      });
    return result.take(limit).toList(growable: false);
  }
}

class _Brand {
  const _Brand(this.name, this.category, this.reason);

  final String name;
  final String category;
  final String reason;
}

class _Candidate {
  const _Candidate(this.name, this.category);

  final String name;
  final String category;
}

class _Rule {
  const _Rule({
    required this.keywords,
    required this.places,
    required this.reason,
    this.exclude = const [],
  });

  final List<String> keywords;
  final List<_Candidate> places;
  final String reason;
  final List<String> exclude;

  bool matches(String text) {
    if (exclude.any(text.contains)) return false;
    return keywords.any(text.contains);
  }
}
