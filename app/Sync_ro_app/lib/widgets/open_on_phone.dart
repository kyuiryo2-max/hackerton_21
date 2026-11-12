import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config/app_theme.dart';

/// PC 웹에서 앱을 열었을 때만 보이는 "폰으로 열기" 버튼.
/// 누르면 지금 주소의 QR코드를 크게 보여 줘서, 휴대폰 카메라로 찍으면 같은 웹 앱이 열려요.
class OpenOnPhoneButton extends StatelessWidget {
  const OpenOnPhoneButton({super.key});

  /// 배포 주소. 다른 곳에 배포하면 --dart-define=SYNC_RO_PUBLIC_URL=... 로 바꿔요.
  static const String publicUrl = String.fromEnvironment(
    'SYNC_RO_PUBLIC_URL',
    defaultValue: 'https://kyuiryo2-max.github.io/hackerton_21/',
  );

  static bool _isLocal(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '0.0.0.0' || host.isEmpty;

  /// 지금 열린 주소(배포본이면 그 주소), 로컬 실행이면 배포 주소를 써요.
  static ({String url, bool fromLocal}) phoneUrl() {
    final base = Uri.base;
    if (!kIsWeb || _isLocal(base.host)) return (url: publicUrl, fromLocal: kIsWeb);
    final clean = Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: base.path,
    );
    return (url: clean.toString(), fromLocal: false);
  }

  static Future<void> show(BuildContext context) {
    final target = phoneUrl();
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 24, 16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('휴대폰으로 열기', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              const Text('휴대폰 카메라로 QR코드를 비추면 바로 열려요.\n설치 없이 브라우저에서 실행돼요.',
                  textAlign: TextAlign.center, style: TextStyle(color: AppTheme.textMuted, height: 1.4)),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppTheme.border),
                ),
                child: QrImageView(
                  data: target.url,
                  version: QrVersions.auto,
                  size: 240,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: AppTheme.textStrong),
                  dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square, color: AppTheme.textStrong),
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(target.url,
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              if (target.fromLocal)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('지금은 PC에서 로컬로 실행 중이라 배포 주소를 보여 줘요.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: AppTheme.warn)),
                ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: target.url));
                      if (dialogContext.mounted) {
                        ScaffoldMessenger.of(dialogContext)
                            .showSnackBar(const SnackBar(content: Text('주소를 복사했어요')));
                      }
                    },
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('주소 복사'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('닫기'),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 휴대폰 앱(Android/iOS)에서는 필요 없으니 숨겨요.
    if (!kIsWeb) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: IconButton(
        tooltip: '휴대폰으로 열기 (QR코드)',
        style: IconButton.styleFrom(
          backgroundColor: AppTheme.primarySoft,
          foregroundColor: AppTheme.primary,
          minimumSize: const Size(36, 36),
          padding: EdgeInsets.zero,
        ),
        onPressed: () => show(context),
        icon: const Icon(Icons.qr_code_2_rounded, size: 20),
      ),
    );
  }
}
