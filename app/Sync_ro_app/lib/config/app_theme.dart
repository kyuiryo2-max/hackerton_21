import 'package:flutter/material.dart';

/// 앱 전체 색·모양. 화면 코드에서는 가능한 한 여기 값을 가져다 써요.
class AppTheme {
  static const Color primary = Color(0xFF4936D8);
  static const Color primaryDark = Color(0xFF2F1FA8);
  static const Color primarySoft = Color(0xFFEEEBFF);
  static const Color background = Color(0xFFF5F5FA);
  static const Color surface = Colors.white;
  static const Color border = Color(0xFFE8E7F0);

  static const Color textStrong = Color(0xFF17162B);
  static const Color textMuted = Color(0xFF6E6C85);

  // 상태 색 (여유 / 빠듯 / 부족)
  static const Color ok = Color(0xFF12A36B);
  static const Color okSoft = Color(0xFFE3F7EE);
  static const Color warn = Color(0xFFE08A00);
  static const Color warnSoft = Color(0xFFFFF3DC);
  static const Color danger = Color(0xFFE5484D);
  static const Color dangerSoft = Color(0xFFFFE9EA);

  static const LinearGradient heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF5B45F0), Color(0xFF3A27C4)],
  );

  static const double radius = 20;

  static ThemeData get lightTheme {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
    ).copyWith(primary: primary, surface: surface);

    // 한글 글꼴을 앱에 넣어 두어, 웹에서 입력 중인 글자가 네모로 깨지지 않게 해요 (11/14)
    final base = ThemeData(useMaterial3: true, colorScheme: colorScheme, fontFamily: 'NotoSansKR');
    final text = base.textTheme.apply(
      bodyColor: textStrong,
      displayColor: textStrong,
    );

    return base.copyWith(
      scaffoldBackgroundColor: background,
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        bodySmall: text.bodySmall?.copyWith(color: textMuted),
      ),

      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: textStrong,
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontSize: 20, fontWeight: FontWeight.w800, color: textStrong, letterSpacing: -0.4),
      ),

      cardTheme: CardThemeData(
        elevation: 0,
        color: surface,
        surfaceTintColor: Colors.transparent,
        margin: const EdgeInsets.symmetric(vertical: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: const BorderSide(color: border),
        ),
      ),

      listTileTheme: const ListTileThemeData(
        iconColor: primary,
        contentPadding: EdgeInsets.symmetric(horizontal: 16),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: border),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 52),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          side: const BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),

      chipTheme: base.chipTheme.copyWith(
        side: const BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: primarySoft,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected) ? FontWeight.w700 : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? primary : textMuted,
        )),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          color: states.contains(WidgetState.selected) ? primary : textMuted,
        )),
      ),

      sliderTheme: base.sliderTheme.copyWith(
        trackHeight: 6,
        activeTrackColor: primary,
        inactiveTrackColor: primarySoft,
        thumbColor: primary,
        overlayColor: primary.withValues(alpha: 0.12),
        valueIndicatorColor: textStrong,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),

      dividerTheme: const DividerThemeData(thickness: 0.8, space: 24, color: border),
    );
  }
}
