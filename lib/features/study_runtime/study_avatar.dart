import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/avatar_audio_bridge.dart';

/// Native DUIX model rendering. The fallback is explicitly identified and does
/// not claim successful initialization or lip synchronization.
class StudyAvatar extends StatefulWidget {
  final bool isSpeaking;
  final VoidCallback? onReady;
  final ValueChanged<String>? onError;
  const StudyAvatar({
    super.key,
    this.isSpeaking = false,
    this.onReady,
    this.onError,
  });
  @override
  State<StudyAvatar> createState() => _StudyAvatarState();
}

class _StudyAvatarState extends State<StudyAvatar> {
  MethodChannel? _channel;
  Timer? _deadline;
  bool _ready = false;
  String? _error;
  int _viewEpoch = 0;

  void _retry() {
    _deadline?.cancel();
    setState(() {
      _viewEpoch++;
      _ready = false;
      _error = null;
    });
  }

  void _failed(String error) {
    if (!mounted || _ready) return;
    _deadline?.cancel();
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      AvatarAudioBridge.detach(channel);
      channel.setMethodCallHandler(null);
    }
    setState(() => _error = error);
    widget.onError?.call(error);
  }

  @override
  void didUpdateWidget(StudyAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isSpeaking != widget.isSpeaking && _ready) {
      unawaited(
        _channel?.invokeMethod<void>('setSpeaking', {
          'speaking': widget.isSpeaking,
        }),
      );
    }
  }

  @override
  void dispose() {
    _deadline?.cancel();
    final channel = _channel;
    if (channel != null) {
      AvatarAudioBridge.detach(channel);
      channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final epoch = _viewEpoch;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xff171b20)),
        Image.asset(
          'assets/study/mentor-preview.webp',
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              const Center(child: Icon(Icons.person, size: 96)),
        ),
        if (_error == null)
          AndroidView(
            key: ValueKey(epoch),
            viewType: 'com.namson.ai_secretary/duix_view',
            creationParams: const {'modelPath': '小秘'},
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: (id) {
              if (!mounted || _error != null || epoch != _viewEpoch) return;
              final channel = MethodChannel(
                'com.namson.ai_secretary/duix_view_$id',
              );
              _channel = channel;
              // Cold resource extraction is part of native initialization.
              // Start the bounded wait once the platform view actually exists.
              _deadline = Timer(const Duration(seconds: 180), () {
                if (mounted && !_ready && identical(_channel, channel)) {
                  _failed('数字人初始化超时，文字与普通语音仍可用');
                }
              });
              channel.setMethodCallHandler((call) async {
                if (!mounted ||
                    _error != null ||
                    !identical(_channel, channel)) {
                  return;
                }
                if (call.method == 'onDuixInitialized') {
                  _deadline?.cancel();
                  AvatarAudioBridge.attach(channel);
                  setState(() {
                    _ready = true;
                    _error = null;
                  });
                  widget.onReady?.call();
                } else if (call.method == 'onDuixError') {
                  _failed('数字人加载失败，文字与普通语音仍可用');
                }
              });
            },
          ),
        if (!_ready)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _error ?? '正在载入数字人…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    if (_error != null)
                      TextButton(
                        onPressed: _retry,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(88, 44),
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('重试数字人'),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
