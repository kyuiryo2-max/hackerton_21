/// 홈 화면 메모 위젯과 앱이 함께 쓰는 메모 한 건.
/// 분류는 '할일'과 '일정' 두 가지만 있어요.
enum MemoType {
  todo('todo', '할일'),
  schedule('schedule', '일정');

  const MemoType(this.value, this.label);

  final String value;
  final String label;

  static MemoType fromValue(String? value) => MemoType.values.firstWhere(
    (type) => type.value == value,
    orElse: () => MemoType.todo,
  );
}

class Memo {
  const Memo({
    required this.id,
    required this.text,
    required this.type,
    required this.createdAt,
    this.done = false,
  });

  /// 위젯(네이티브)과 같은 값을 쓰려고 생성 시각(ms)을 그대로 ID로 써요.
  final int id;
  final String text;
  final MemoType type;
  final DateTime createdAt;
  final bool done;

  Memo copyWith({String? text, MemoType? type, bool? done}) {
    return Memo(
      id: id,
      text: text ?? this.text,
      type: type ?? this.type,
      createdAt: createdAt,
      done: done ?? this.done,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'type': type.value,
    'done': done,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  factory Memo.fromJson(Map<String, dynamic> json) {
    return Memo(
      id: (json['id'] as num?)?.toInt() ?? 0,
      text: (json['text'] as String?)?.trim() ?? '',
      type: MemoType.fromValue(json['type'] as String?),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['created_at'] as num?)?.toInt() ?? 0,
      ),
      done: json['done'] as bool? ?? false,
    );
  }
}
