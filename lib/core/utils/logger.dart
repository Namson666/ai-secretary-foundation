import 'package:flutter/foundation.dart';

class Logger {
  static void d(String tag, String message) {
    debugPrint('[$tag] $message');
  }

  static void e(String tag, String message) {
    debugPrint('[$tag][ERROR] $message');
  }

  static void w(String tag, String message) {
    debugPrint('[$tag][WARN] $message');
  }

  static void i(String tag, String message) {
    debugPrint('[$tag][INFO] $message');
  }
}
