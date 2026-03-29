import 'package:flutter/material.dart';

abstract final class AppTheme {
  static ThemeData get light {
    const seedColor = Color(0xFF1565C0);
    const appBarForeground = Color(0xFF0F172A);
    const List<String> fontFallback = <String>[
      'Segoe UI',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'PingFang SC',
      'Hiragino Sans GB',
      'Noto Sans CJK SC',
      'Source Han Sans SC',
      'WenQuanYi Micro Hei',
    ];

    final TextTheme baseTextTheme = Typography.material2021().black.apply(
          bodyColor: const Color(0xFF111827),
          displayColor: const Color(0xFF111827),
        );
    final TextTheme textTheme = baseTextTheme.copyWith(
      titleMedium: baseTextTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        fontFamilyFallback: fontFallback,
      ),
      titleSmall: baseTextTheme.titleSmall?.copyWith(
        fontWeight: FontWeight.w700,
        fontFamilyFallback: fontFallback,
      ),
      bodyLarge: baseTextTheme.bodyLarge?.copyWith(
        fontFamilyFallback: fontFallback,
      ),
      bodyMedium: baseTextTheme.bodyMedium?.copyWith(
        fontFamilyFallback: fontFallback,
      ),
      bodySmall: baseTextTheme.bodySmall?.copyWith(
        fontFamilyFallback: fontFallback,
      ),
      labelLarge: baseTextTheme.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        fontFamilyFallback: fontFallback,
      ),
      labelMedium: baseTextTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        fontFamilyFallback: fontFallback,
      ),
      labelSmall: baseTextTheme.labelSmall?.copyWith(
        fontFamilyFallback: fontFallback,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      fontFamilyFallback: fontFallback,
      textTheme: textTheme,
      primaryTextTheme: textTheme,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seedColor,
        brightness: Brightness.light,
      ),
      scaffoldBackgroundColor: const Color(0xFFF5F7FB),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: Color(0xFFF5F7FB),
        foregroundColor: appBarForeground,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: TextStyle(
          color: appBarForeground,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          fontFamilyFallback: fontFallback,
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        labelStyle: textTheme.labelLarge?.copyWith(
          color: const Color(0xFF374151),
        ),
        floatingLabelStyle: textTheme.labelLarge?.copyWith(
          color: const Color(0xFF1565C0),
        ),
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF6B7280),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
