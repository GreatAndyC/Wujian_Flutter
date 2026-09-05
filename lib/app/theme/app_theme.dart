import 'package:flutter/material.dart';

class AppTheme {
  static const Color ink = Color(0xFF11211E);
  static const Color moss = Color(0xFF1E6B57);
  static const Color mint = Color(0xFFBFE6D3);
  static const Color sand = Color(0xFFF5F1E8);
  static const Color coral = Color(0xFFE9885D);

  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 20;
  static const double radiusXl = 28;

  static ThemeData lightTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: moss,
      brightness: Brightness.light,
      primary: moss,
      secondary: coral,
      surface: const Color(0xFFFFFCF7),
      surfaceContainerLowest: Colors.white,
      surfaceContainerLow: const Color(0xFFFFF8F0),
      surfaceContainer: const Color(0xFFF9F1E8),
      surfaceContainerHigh: const Color(0xFFF2EAE1),
      surfaceContainerHighest: const Color(0xFFECE3D9),
    );

    return _buildTheme(
      scheme,
      scaffoldBackgroundColor: sand,
      brightness: Brightness.light,
    );
  }

  static ThemeData darkTheme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: mint,
      brightness: Brightness.dark,
      primary: mint,
      secondary: const Color(0xFFFFB28D),
      surface: const Color(0xFF101A17),
    );
    return _buildTheme(
      scheme,
      scaffoldBackgroundColor: const Color(0xFF0B1210),
      brightness: Brightness.dark,
    );
  }

  static ThemeData _buildTheme(
    ColorScheme scheme, {
    required Color scaffoldBackgroundColor,
    required Brightness brightness,
  }) {
    final isLight = brightness == Brightness.light;
    final inkColor = isLight ? ink : const Color(0xFFE7F0EA);
    final mutedColor = isLight
        ? const Color(0xFF52625C)
        : const Color(0xFFB7C8BE);
    final borderColor = scheme.outlineVariant.withValues(alpha: 0.62);

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scaffoldBackgroundColor,
      textTheme: TextTheme(
        displaySmall: TextStyle(
          fontSize: 36,
          fontWeight: FontWeight.w700,
          color: inkColor,
          height: 1.05,
        ),
        headlineSmall: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: inkColor,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: inkColor,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: inkColor,
        ),
        bodyLarge: TextStyle(fontSize: 15, color: inkColor, height: 1.5),
        bodyMedium: TextStyle(fontSize: 14, color: mutedColor, height: 1.45),
        bodySmall: TextStyle(fontSize: 12, color: mutedColor, height: 1.35),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: inkColor,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        shadowColor: Colors.black.withValues(alpha: 0.04),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: BorderSide(color: borderColor),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 15,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: borderColor),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: borderColor),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: scheme.error, width: 1.5),
        ),
        hintStyle: TextStyle(color: mutedColor),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 74,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.onSurface
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: scheme.onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMd),
          ),
          side: BorderSide(color: borderColor),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(99),
          side: BorderSide(color: borderColor),
        ),
        side: BorderSide(color: borderColor),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      dividerTheme: DividerThemeData(
        color: borderColor,
        thickness: 1,
        space: 1,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
    );
  }
}
