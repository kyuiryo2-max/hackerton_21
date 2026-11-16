import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../models/memo.dart';
import '../services/memo_classifier.dart';
import '../services/memo_storage_service.dart';

/// 홈 화면 위젯 하단 입력줄을 눌렀을 때 열리는 한 줄 메모 화면.
/// 저장할 때 문장을 일정/할일로 나눠 위젯과 같은 메모 저장소에 넣어요.
class MemoQuickCaptureScreen extends StatefulWidget {
  const MemoQuickCaptureScreen({super.key});

  @override
  State<MemoQuickCaptureScreen> createState() => _MemoQuickCaptureScreenState();
}

class _MemoQuickCaptureScreenState extends State<MemoQuickCaptureScreen> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final MemoStorageService _storage = MemoStorageService();
  final MemoClassifier _classifier = MemoClassifier();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _classifier.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _saving) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final classification = await _classifier.classify(text);
      final memos = List<Memo>.of(await _storage.load());
      if (!mounted) return;

      final now = DateTime.now();
      var id = now.millisecondsSinceEpoch;
      for (final memo in memos) {
        if (memo.id >= id) id = memo.id + 1;
      }
      memos.add(
        Memo(id: id, text: text, type: classification.type, createdAt: now),
      );
      await _storage.save(memos);
      if (!mounted) return;
      Navigator.of(context).pop(classification);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '메모를 저장하지 못했어요: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('빠른 메모'),
          leading: IconButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            tooltip: '닫기',
            icon: const Icon(Icons.close),
          ),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildGuide(),
                const SizedBox(height: 18),
                TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: true,
                  enabled: !_saving,
                  minLines: 3,
                  maxLines: 6,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.45,
                    color: AppTheme.textStrong,
                  ),
                  decoration: const InputDecoration(
                    hintText: '예: 내일 오후 3시 치과 예약\n또는 우유 사기',
                    hintStyle: TextStyle(height: 1.45),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  '날짜·시간이나 할 일 표현이 분명하면 바로 분류하고, 애매한 문장은 AI가 한 번 더 판단해요.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: AppTheme.textMuted,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.danger,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _saving ? null : _submit,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.auto_awesome, size: 19),
                  label: Text(_saving ? 'AI가 분류하고 있어요...' : 'AI로 분류해서 위젯에 추가'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGuide() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.primarySoft,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.auto_awesome,
              size: 20,
              color: AppTheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '한 줄만 적으면 알아서 정리해요',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textStrong,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  '입력한 메모를 일정 또는 할일로 판단해 홈 화면 위젯과 메모 탭에 바로 추가합니다.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
