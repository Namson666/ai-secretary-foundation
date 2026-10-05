import 'package:flutter/material.dart';
import 'features/study/presentation/study_shell.dart';

class StudyApp extends StatelessWidget {
  const StudyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '拾语',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff101214),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff4fbfa4),
        brightness: Brightness.dark,
        surface: const Color(0xff1b1f20),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff101214),
        surfaceTintColor: Colors.transparent,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xff101214),
        indicatorColor: Color(0xff25423b),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xff1b1f20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: const CardThemeData(color: Color(0xff1b1f20), elevation: 0),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(height: 1.6),
        bodyMedium: TextStyle(height: 1.5),
      ),
    ),
    home: const StudyShell(),
  );
}
