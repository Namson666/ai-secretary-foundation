import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/logger.dart';
import '../../../providers/digital_human_provider.dart';
import '../../../services/local_streaming_asr_service.dart';
import '../../../shared/theme/app_theme.dart';

/// States of the voice button lifecycle.
enum _VoiceState {
  /// Default — mic icon shown, no recording.
  idle,

  /// User is holding the button and recording.
  recording,

  /// Finger has slid into the "cancel" zone.
  cancelling,

  /// ASR is processing the recorded audio.
  processing,

  /// An error occurred.
  error,
}

/// A press-and-hold voice input button.
///
/// Behaviour:
/// - **Hold** to start recording.
/// - **Release** to send audio to ASR and get back recognised text.
/// - **Slide up** past the threshold to cancel.
/// - Visual feedback shows the current state with a ripple / colour change.
class VoiceButton extends ConsumerStatefulWidget {
  /// Called with the recognised text from ASR.
  final void Function(String text) onResult;
  final void Function(String text)? onPartial;
  final VoidCallback? onCancel;

  /// Called when an error occurs.
  final void Function(String message)? onError;

  const VoiceButton({
    super.key,
    required this.onResult,
    this.onPartial,
    this.onCancel,
    this.onError,
  });

  @override
  ConsumerState<VoiceButton> createState() => _VoiceBtnState();
}

class _VoiceBtnState extends ConsumerState<VoiceButton>
    with SingleTickerProviderStateMixin {
  late final LocalStreamingAsrService _asrService;

  _VoiceState _state = _VoiceState.idle;
  String? _errorMessage;

  // Animation for the recording pulse
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  // Cancel threshold (logical pixels from button center)
  static const double _cancelThreshold = 80.0;

  // Last known Y offset for cancel detection
  double _dySinceStart = 0;

  @override
  void initState() {
    super.initState();
    _asrService = ref.read(localStreamingAsrProvider);
    _asrService.prepare().catchError((Object error) {
      Logger.w('VoiceButton', 'Local ASR preload failed: $error');
    });
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.3).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _pulseController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _pulseController.dispose();
    if (_state == _VoiceState.recording || _state == _VoiceState.cancelling) {
      _asrService.cancel();
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Gesture handlers
  // ---------------------------------------------------------------------------

  Future<void> _onLongPressStart(LongPressStartDetails details) async {
    if (_state == _VoiceState.processing) return;

    setState(() {
      _state = _VoiceState.recording;
      _errorMessage = null;
      _dySinceStart = 0;
    });
    _pulseController.repeat(reverse: true);

    try {
      await _asrService.start((text) {
        if (!mounted ||
            (_state != _VoiceState.recording &&
                _state != _VoiceState.cancelling)) {
          return;
        }
        widget.onPartial?.call(text);
      });
    } catch (e) {
      Logger.e('VoiceButton', 'Local ASR start failed: $e');
      if (mounted && _state == _VoiceState.recording) {
        _setError('无法开始本地语音识别: $e');
      }
    }
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_state != _VoiceState.recording && _state != _VoiceState.cancelling) {
      return;
    }

    _dySinceStart = details.localOffsetFromOrigin.dy;

    // Check if finger slid up past the cancel threshold
    if (_dySinceStart < -_cancelThreshold) {
      if (_state != _VoiceState.cancelling) {
        setState(() => _state = _VoiceState.cancelling);
      }
    } else {
      if (_state == _VoiceState.cancelling) {
        setState(() => _state = _VoiceState.recording);
      }
    }
  }

  Future<void> _onLongPressEnd(LongPressEndDetails details) async {
    if (_state != _VoiceState.recording && _state != _VoiceState.cancelling) {
      return;
    }

    _pulseController.stop();
    _pulseController.reset();

    // Slide to cancel
    if (_state == _VoiceState.cancelling) {
      await _asrService.cancel();
      if (mounted) setState(() => _state = _VoiceState.idle);
      widget.onCancel?.call();
      return;
    }

    // Cancel if finger moved up significantly
    if (_dySinceStart < -_cancelThreshold) {
      await _asrService.cancel();
      if (mounted) setState(() => _state = _VoiceState.idle);
      widget.onCancel?.call();
      return;
    }

    // Process the recording
    setState(() => _state = _VoiceState.processing);

    try {
      final text = (await _asrService.finish()).trim();
      if (!mounted) return;
      setState(() => _state = _VoiceState.idle);

      if (text.isNotEmpty) {
        widget.onResult(text);
      } else {
        widget.onCancel?.call();
        _setError('没有识别到语音，请重试');
      }
    } catch (e) {
      Logger.e('VoiceButton', 'ASR failed: $e');
      if (mounted) {
        widget.onCancel?.call();
        _setError('本地语音识别失败: $e');
      }
    }
  }

  void _onLongPressCancel() {
    _pulseController.stop();
    _pulseController.reset();
    _asrService.cancel();
    setState(() => _state = _VoiceState.idle);
    widget.onCancel?.call();
  }

  void _setError(String message) {
    setState(() {
      _state = _VoiceState.error;
      _errorMessage = message;
    });
    widget.onError?.call(message);

    // Auto-recover after a short delay
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _state = _VoiceState.idle;
          _errorMessage = null;
        });
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Cancel hint (appears when sliding up)
        if (_state == _VoiceState.cancelling)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              '松开取消',
              style: TextStyle(
                color: AppTheme.accentOrange.withValues(alpha: 0.9),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

        // The button itself
        Semantics(
          button: true,
          enabled: _state != _VoiceState.processing,
          label: _semanticLabel,
          hint: '长按录音，松开发送，上滑取消',
          child: GestureDetector(
            onLongPressStart: _onLongPressStart,
            onLongPressMoveUpdate: _onLongPressMoveUpdate,
            onLongPressEnd: _onLongPressEnd,
            onLongPressCancel: _onLongPressCancel,
            // Allow the button to be pressed when streaming — voice is independent
            child: _buildButton(),
          ),
        ),

        // Error message
        if (_state == _VoiceState.error && _errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SizedBox(
              width: 140,
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 9),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildButton() {
    // Base dimensions
    const double size = 40;

    // Determine colour and icon based on state
    Color bgColor;
    Color iconColor;
    IconData icon;
    double scale = 1.0;

    switch (_state) {
      case _VoiceState.idle:
        bgColor = AppTheme.surfaceColor;
        iconColor = AppTheme.textSecondary;
        icon = Icons.mic;
      case _VoiceState.recording:
        bgColor = AppTheme.accentGreen;
        iconColor = Colors.white;
        icon = Icons.mic;
        scale = _pulseAnimation.value;
      case _VoiceState.cancelling:
        bgColor = AppTheme.accentOrange;
        iconColor = Colors.white;
        icon = Icons.keyboard_arrow_up;
      case _VoiceState.processing:
        bgColor = AppTheme.accentCyan;
        iconColor = Colors.white;
        icon = Icons.hourglass_top;
      case _VoiceState.error:
        bgColor = Colors.redAccent;
        iconColor = Colors.white;
        icon = Icons.error_outline;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        boxShadow: _state == _VoiceState.recording
            ? [
                BoxShadow(
                  color: AppTheme.accentGreen.withValues(alpha: 0.4),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Transform.scale(
        scale: scale,
        child: Center(child: Icon(icon, color: iconColor, size: 20)),
      ),
    );
  }

  String get _semanticLabel {
    return switch (_state) {
      _VoiceState.idle => '语音输入',
      _VoiceState.recording => '正在录音',
      _VoiceState.cancelling => '松开取消语音输入',
      _VoiceState.processing => '正在识别语音',
      _VoiceState.error => '语音输入出错',
    };
  }
}
