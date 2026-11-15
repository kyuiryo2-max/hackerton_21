import 'package:flutter/material.dart';

import '../config/app_theme.dart';

/// 네이버 지도 길찾기처럼 출발지·도착지를 한 상자에 두고, 눌러서 바꾸고 ⇅로 뒤집어요 (11/14).
/// 일정 입력 화면과 이동 탭이 같이 써요.
class RouteEndpoints extends StatelessWidget {
  const RouteEndpoints({
    super.key,
    required this.originLabel,
    required this.destinationLabel,
    required this.onTapOrigin,
    required this.onTapDestination,
    required this.onSwap,
    this.originHint = '출발지 검색',
    this.destinationHint = '도착지 검색',
    this.originSub,
    this.destinationSub,
    this.busy = false,
  });

  /// 비어 있으면 [originHint]를 흐리게 보여 줘요
  final String? originLabel;
  final String? destinationLabel;
  final VoidCallback onTapOrigin;
  final VoidCallback onTapDestination;
  final VoidCallback? onSwap;
  final String originHint;
  final String destinationHint;
  /// 이름 아래 작은 글씨 (주소 등)
  final String? originSub;
  final String? destinationSub;
  /// 바꾼 뒤 경로를 찾는 중이면 ⇅ 대신 진행 표시
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border),
      ),
      child: Row(children: [
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _Field(
              dot: AppTheme.ok,
              label: originLabel,
              hint: originHint,
              sub: originSub,
              onTap: onTapOrigin,
              semantic: '출발지',
            ),
            const Divider(height: 1, indent: 26),
            _Field(
              dot: AppTheme.danger,
              label: destinationLabel,
              hint: destinationHint,
              sub: destinationSub,
              onTap: onTapDestination,
              semantic: '도착지',
            ),
          ]),
        ),
        SizedBox(
          width: 48,
          child: busy
              ? const Center(
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
              : IconButton(
                  tooltip: '출발지와 도착지 바꾸기',
                  onPressed: onSwap,
                  icon: const Icon(Icons.swap_vert_rounded, color: AppTheme.primary),
                ),
        ),
      ]),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.dot,
    required this.label,
    required this.hint,
    required this.onTap,
    required this.semantic,
    this.sub,
  });

  final Color dot;
  final String? label;
  final String hint;
  final String? sub;
  final VoidCallback onTap;
  final String semantic;

  @override
  Widget build(BuildContext context) {
    final empty = label == null || label!.trim().isEmpty;
    return Semantics(
      button: true,
      label: '$semantic ${empty ? hint : label}',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(
                  empty ? hint : label!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: empty ? FontWeight.w500 : FontWeight.w700,
                    color: empty ? AppTheme.textMuted : AppTheme.textStrong,
                  ),
                ),
                if (!empty && sub != null && sub!.trim().isNotEmpty)
                  Text(sub!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: AppTheme.textMuted)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
