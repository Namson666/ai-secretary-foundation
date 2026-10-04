import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../providers/digital_human_provider.dart';
import '../../../services/avatar_audio_bridge.dart';

/// DUIX 数字人视图组件
///
/// 封装 AndroidView 与原生 DUIX 渲染层的通信。
/// 情感变化通过 MethodChannel 发送 emotion 类型，原生端映射为 startMotion() 调用。
/// 身体动作（nod/wave/shakeHead/smile/idle）通过 bodyAction 通道映射。
class DuixAvatarView extends StatefulWidget {
  final EmotionType emotion;
  final bool isSpeaking;
  final VoidCallback? onInitialized;

  const DuixAvatarView({
    super.key,
    required this.emotion,
    required this.isSpeaking,
    this.onInitialized,
  });

  @override
  State<DuixAvatarView> createState() => DuixAvatarViewState();
}

class DuixAvatarViewState extends State<DuixAvatarView> {
  MethodChannel? _viewChannel;
  bool _shouldCreatePlatformView = false;
  Timer? _platformViewTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _platformViewTimer = Timer(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        setState(() => _shouldCreatePlatformView = true);
      });
    });
  }

  /// 推送 PCM 音频到 DUIX 数字人（驱动嘴形+发声）
  Future<void> pushPcm(List<int> pcm) async {
    final ch = _viewChannel;
    if (ch == null) return;
    try {
      await ch.invokeMethod('pushPcm', {'pcm': Uint8List.fromList(pcm)});
    } catch (_) {}
  }

  Future<void> startPush() async {
    final ch = _viewChannel;
    if (ch == null) return;
    try {
      await ch.invokeMethod('startPush');
    } catch (_) {}
  }

  Future<void> stopPush() async {
    final ch = _viewChannel;
    if (ch == null) return;
    try {
      await ch.invokeMethod('stopPush');
    } catch (_) {}
  }

  /// 身体动作控制
  Future<void> bodyAction(String action) async {
    final ch = _viewChannel;
    if (ch == null) return;
    try {
      await ch.invokeMethod('bodyAction', {'action': action});
    } catch (_) {}
  }

  /// 点头动作
  Future<void> nod() async => bodyAction('nod');

  /// 挥手动作
  Future<void> wave() async => bodyAction('wave');

  /// 摇头动作
  Future<void> shakeHead() async => bodyAction('shakeHead');

  /// 微笑动作
  Future<void> smile() async => bodyAction('smile');

  /// 空闲姿态
  Future<void> idle() async => bodyAction('idle');

  /// 根据对话内容触发相应身体动作
  Future<void> triggerActionByContent(String content) async {
    if (content.contains('你好') ||
        content.contains('早上好') ||
        content.contains('下午好')) {
      await nod();
      await Future.delayed(const Duration(milliseconds: 300));
      await wave();
    } else if (content.contains('再见') ||
        content.contains('拜拜') ||
        content.contains('晚安')) {
      await wave();
    } else if (content.contains('对') ||
        content.contains('是') ||
        content.contains('没错') ||
        content.contains('好的')) {
      await nod();
    } else if (content.contains('不') ||
        content.contains('不对') ||
        content.contains('没有')) {
      await shakeHead();
    } else if (content.contains('开心') ||
        content.contains('高兴') ||
        content.contains('好棒') ||
        content.contains('恭喜')) {
      await smile();
    } else {
      await idle();
    }
  }

  @override
  void didUpdateWidget(DuixAvatarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.emotion != widget.emotion) {
      _notifyEmotionChange(widget.emotion);
    }
    if (oldWidget.isSpeaking != widget.isSpeaking) {
      _notifySpeakingChange(widget.isSpeaking);
    }
  }

  @override
  void dispose() {
    _platformViewTimer?.cancel();
    final channel = _viewChannel;
    if (channel != null) {
      AvatarAudioBridge.detach(channel);
      channel.setMethodCallHandler(null);
    }
    super.dispose();
  }

  Future<void> _notifyEmotionChange(EmotionType emotion) async {
    final ch = _viewChannel;
    if (ch == null) return;
    try {
      await ch.invokeMethod('setEmotion', {
        'emotion': emotionToSDKString(emotion),
      });
    } catch (_) {}
  }

  Future<void> _notifySpeakingChange(bool isSpeaking) async {
    final ch = _viewChannel;
    if (ch == null) return;
    try {
      await ch.invokeMethod('setSpeaking', {'speaking': isSpeaking});
    } catch (_) {}
  }

  /// EmotionType -> DUIX SDK emotion string
  String emotionToSDKString(EmotionType emotion) {
    switch (emotion) {
      case EmotionType.happy:
        return 'happy';
      case EmotionType.excited:
        return 'excited';
      case EmotionType.sad:
        return 'sad';
      case EmotionType.concerned:
        return 'worried';
      case EmotionType.surprised:
        return 'surprised';
      case EmotionType.serious:
        return 'serious';
      case EmotionType.gentle:
        return 'gentle';
      default:
        return 'neutral';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_shouldCreatePlatformView) {
      return const SizedBox.expand();
    }

    return SizedBox.expand(
      child: AndroidView(
        viewType: 'com.namson.ai_secretary/duix_view',
        creationParams: <String, dynamic>{'modelPath': '小秘'},
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: (id) {
          _viewChannel = MethodChannel('com.namson.ai_secretary/duix_view_$id');
          _viewChannel?.setMethodCallHandler((call) async {
            if (call.method == 'onDuixInitialized') {
              AvatarAudioBridge.attach(_viewChannel!);
              widget.onInitialized?.call();
            }
            return null;
          });
        },
      ),
    );
  }
}
