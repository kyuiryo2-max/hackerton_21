import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/memo.dart';
import 'home_widget_bridge.dart';

/// 메모는 홈 화면 위젯(네이티브)과 앱이 같은 SharedPreferences 키를 읽고 써요.
/// 그래서 앱을 열지 않고 위젯에서 적은 메모도 앱의 메모 탭에 바로 보여요.
class MemoStorageService {
  static const String storageKey = 'sync_ro_memos_v1';

  /// 위젯이나 다른 화면에서 메모가 바뀌었을 때 화면을 다시 읽게 하는 신호.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<List<Memo>> load() async {
    final prefs = await SharedPreferences.getInstance();
    // 네이티브 위젯이 같은 파일에 쓴 내용을 읽으려면 캐시를 비워야 해요.
    try {
      await prefs.reload();
    } catch (_) {
      // 웹처럼 reload를 지원하지 않는 플랫폼은 기존 캐시를 그대로 써요.
    }
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return const [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final memos = decoded
          .whereType<Map>()
          .map((item) => Memo.fromJson(Map<String, dynamic>.from(item)))
          .where((memo) => memo.text.isNotEmpty)
          .toList();
      memos.sort(_compare);
      return memos;
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<Memo> memos) async {
    final prefs = await SharedPreferences.getInstance();
    final sorted = List<Memo>.of(memos)..sort(_compare);
    await prefs.setString(
      storageKey,
      jsonEncode(sorted.map((memo) => memo.toJson()).toList()),
    );
    revision.value++;
    await HomeWidgetBridge.refresh();
  }

  static int _compare(Memo a, Memo b) {
    if (a.done != b.done) return a.done ? 1 : -1;
    return b.createdAt.compareTo(a.createdAt);
  }
}
