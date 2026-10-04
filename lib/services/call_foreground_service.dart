import 'dart:io';

import 'package:flutter/services.dart';

class CallForegroundService {
  static const _channel = MethodChannel('com.namson.ai_secretary/call');
  static Future<void> Function()? _stopRequested;
  static void Function()? _returnRequested;
  static Object? _stopOwner;
  static Object? _returnOwner;
  static bool _handlerInstalled = false;

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') await _stopRequested?.call();
      if (call.method == 'openRequested') _returnRequested?.call();
    });
  }

  /// The returned disposer removes only this registration, even when the same
  /// callback is registered again by a replacement owner.
  static void Function() onStopRequested(Future<void> Function() callback) {
    final owner = Object();
    _stopOwner = owner;
    _stopRequested = callback;
    _installHandler();
    return () {
      if (!identical(_stopOwner, owner)) return;
      _stopOwner = null;
      _stopRequested = null;
    };
  }

  static void Function() onReturnRequested(void Function() callback) {
    final owner = Object();
    _returnOwner = owner;
    _returnRequested = callback;
    _installHandler();
    return () {
      if (!identical(_returnOwner, owner)) return;
      _returnOwner = null;
      _returnRequested = null;
    };
  }

  static Future<void> start() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('start');
  }

  static Future<void> stop() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stop');
  }
}
