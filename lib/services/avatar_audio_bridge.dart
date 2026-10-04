import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The mounted, ready avatar owns audio playback and lip synchronization.
class AvatarAudioBridge {
  static MethodChannel? _channel;

  static void attach(MethodChannel channel) => _channel = channel;

  static void detach(MethodChannel channel) {
    if (_channel == channel) {
      _channel = null;
    }
  }

  static Future<bool> play(Uint8List pcm) async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return false;
    }
    final channel = _channel;
    if (channel == null) return false;
    if (pcm.isEmpty || pcm.length.isOdd) {
      throw const FormatException('Invalid 16-bit PCM audio');
    }
    try {
      return await channel
              .invokeMethod<bool>('playPcm', {'pcm': pcm})
              .timeout(Duration(seconds: (pcm.length / 32000).ceil() + 30)) ??
          false;
    } catch (_) {
      // A replacement avatar may have attached while this request was pending.
      // Clean up the captured view and preserve the original playback failure.
      try {
        await _stopChannel(channel);
      } catch (_) {
        // Cleanup must never replace the error that caused it.
      }
      rethrow;
    }
  }

  static Future<void> stop() => _stopChannel(_channel);

  static Future<void> _stopChannel(MethodChannel? channel) async {
    try {
      await channel?.invokeMethod<void>('stopAudio');
    } on PlatformException {
      // The platform view may already be tearing down.
    } on MissingPluginException {
      // No mounted Android avatar.
    }
  }
}
