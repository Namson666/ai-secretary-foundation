import 'dart:io';

import 'package:flutter/services.dart';

class CallForegroundService {
  static const _channel = MethodChannel('com.namson.ai_secretary/call');
  static Future<void> Function()? _stopRequested;
  static void Function()? _returnRequested;
  static bool _handlerInstalled = false;

  static void _installHandler() {
    if (!Platform.isAndroid || _handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') await _stopRequested?.call();
      if (call.method == 'openRequested') _returnRequested?.call();
    });
  }

  static void onStopRequested(Future<void> Function() callback) {
    _stopRequested = callback;
    _installHandler();
  }

  static void onReturnRequested(void Function() callback) {
    _returnRequested = callback;
    _installHandler();
  }

  static Future<void> start() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('start');
  }

  static Future<void> stop() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stop');
  }
}
