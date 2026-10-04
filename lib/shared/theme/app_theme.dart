import 'package:flutter/material.dart';

class AppTheme {
  static const Color primaryColor = Color(0xFF00C853);
  static const Color backgroundColor = Color(0xFF212121);
  static const Color surfaceColor = Color(0xFF2C2C2C);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0B0B0);

  // 扩展颜色
  static const Color bgCard = Color(0xFF1E1E1E);
  static const Color divider = Color(0xFF3A3A3A);
  static const Color textHint = Color(0xFF757575);
  static const Color bgSurface = Color(0xFF2C2C2C);
  static const Color accentGreen = primaryColor;
  static const Color accentCyan = Color(0xFF00BCD4);
  static const Color accentOrange = Color(0xFFFF9800);
  static const Color accentPink = Color(0xFFE91E63);

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: primaryColor,
      scaffoldBackgroundColor: backgroundColor,
      colorScheme: const ColorScheme.dark(
        primary: primaryColor,
        secondary: primaryColor,
        surface: surfaceColor,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: backgroundColor,
        elevation: 0,
      ),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: textPrimary),
        bodyMedium: TextStyle(color: textSecondary),
      ),
    );
  }
}
