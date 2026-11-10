import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const primary = Color(0xFF6C4CF5);
  static const primaryPressed = Color(0xFF5B3DE2);

  static final light = _buildTheme(
    brightness: Brightness.light,
    background: const Color(0xFFF6F7FB),
    surface: Colors.white,
    text: const Color(0xFF121826),
    secondaryText: const Color(0xFF667085),
    border: const Color(0xFFE7EAF0),
  );

  static final dark = _buildTheme(
    brightness: Brightness.dark,
    background: const Color(0xFF0C1222),
    surface: const Color(0xFF11192D),
    text: const Color(0xFFF2F5FB),
    secondaryText: const Color(0xFFA9B5C9),
    border: const Color(0xFF22304A),
  );

  static ThemeData _buildTheme({
    required Brightness brightness,
    required Color background,
    required Color surface,
    required Color text,
    required Color secondaryText,
    required Color border,
  }) {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: brightness,
    ).copyWith(
      primary: brightness == Brightness.dark ? const Color(0xFF7C62FF) : primary,
      surface: surface,
      onSurface: text,
      outline: border,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      textTheme: ThemeData(brightness: brightness).textTheme.apply(
            fontFamily: 'Avenir Next',
            bodyColor: text,
            displayColor: text,
          ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: secondaryText.withValues(alpha: 0.8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 1.5),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          backgroundColor: primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: primary.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: border),
        ),
      ),
      dividerColor: border,
    );
  }
}
