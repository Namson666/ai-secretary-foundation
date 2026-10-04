import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../shared/theme/app_theme.dart';
import '../../../providers/digital_human_provider.dart';
import '../../../core/utils/logger.dart';
import '../../../shared/home_route_observer.dart';
import '../widgets/duix_avatar_view.dart';
import '../../chat/screens/chat_history_sheet.dart';

/// 数字人首页
///
/// 全屏 DUIX 数字人视图，底部有语音/键盘控制栏，
/// 右上角有设置、聊天记录和可注入的领域入口。
class HomeScreen extends ConsumerStatefulWidget {
  final bool isVisible;
  final Widget? extraControls;
  final VoidCallback? onSpecialistTap;
  final String specialistLabel;
  final double bottomBarHeight;
  const HomeScreen({
    super.key,
    this.isVisible = true,
    this.extraControls,
    this.onSpecialistTap,
    this.specialistLabel = '领域功能',
    this.bottomBarHeight = 64,
  });

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with RouteAware {
  final _textController = TextEditingController();
  final _textFocus = FocusNode();
  bool _typing = false;
  bool _avatarReady = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(localStreamingAsrProvider).prepare().catchError((Object error) {
        Logger.w('HomeScreen', 'Local ASR preload failed: $error');
      });
      unawaited(ref.read(digitalHumanProvider.notifier).resumeCallIfNeeded());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) homeRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    unawaited(ref.read(digitalHumanProvider.notifier).resumeCallIfNeeded());
  }

  @override
  void didUpdateWidget(HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isVisible && widget.isVisible) _avatarReady = false;
  }

  @override
  void dispose() {
    homeRouteObserver.unsubscribe(this);
    _textController.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _sendText() {
    final text = _textController.text.trim();
    final state = ref.read(digitalHumanProvider);
    if (text.isEmpty || state.isProcessing || state.isRecording) return;
    _textController.clear();
    ref.read(digitalHumanProvider.notifier).sendTextInput(text);
  }

  void _toggleTyping() {
    setState(() => _typing = !_typing);
    if (_typing) {
      _textFocus.requestFocus();
    } else {
      _textFocus.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(digitalHumanProvider);
    final media = MediaQuery.of(context);
    final bottomInset = media.viewInsets.bottom > 0
        ? media.viewInsets.bottom + 12
        : media.viewPadding.bottom + widget.bottomBarHeight + 12;
    final status = state.errorMessage.isNotEmpty
        ? state.errorMessage
        : state.isRecording
        ? '正在聆听...'
        : state.isProcessing
        ? '思考中...'
        : state.isSpeaking
        ? '正在回答'
        : state.isCallActive
        ? '实时通话中 · 正在聆听'
        : '';

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ==================== DUIX 数字人视图 ====================
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            child: Stack(
              children: [
                if (widget.isVisible)
                  IgnorePointer(
                    child: DuixAvatarView(
                      emotion: state.emotion,
                      isSpeaking: state.isSpeaking,
                      onInitialized: () {
                        if (!mounted) return;
                        setState(() => _avatarReady = true);
                        ref
                            .read(digitalHumanProvider.notifier)
                            .setInitialized();
                      },
                    ),
                  ),
                // Fallback animation overlay (shown on top while DUIX loads)
                if (widget.isVisible && !_avatarReady)
                  _buildFallbackAnimation(),
              ],
            ),
          ),

          // ==================== 顶部渐变遮罩 ====================
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black54, Colors.transparent],
                ),
              ),
            ),
          ),

          // ==================== 右上角图标 ====================
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _topIconButton(
                  context,
                  Icons.settings,
                  '设置',
                  onTap: () => context.push('/settings'),
                ),
                const SizedBox(width: 8),
                _topIconButton(
                  context,
                  Icons.history,
                  '聊天记录',
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => const ChatHistorySheet(),
                    );
                  },
                ),
                if (widget.onSpecialistTap != null) ...[
                  const SizedBox(width: 8),
                  _topIconButton(
                    context,
                    Icons.swap_horiz,
                    widget.specialistLabel,
                    onTap: widget.onSpecialistTap!,
                  ),
                ],
              ],
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 260,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
              ),
            ),
          ),
          // ==================== 底部控制区域 ====================
          Positioned(
            bottom: bottomInset,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (status.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        status,
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                        ),
                      ),
                    ),
                  if (widget.extraControls != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: media.size.height * .25,
                      ),
                      child: SingleChildScrollView(
                        child: widget.extraControls!,
                      ),
                    ),
                  if (_typing)
                    Material(
                      color: const Color(0xE6212121),
                      borderRadius: BorderRadius.circular(8),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '切换语音',
                            onPressed: _toggleTyping,
                            icon: const Icon(
                              Icons.mic_none,
                              color: Colors.white70,
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              key: const Key('avatar-text-input'),
                              controller: _textController,
                              focusNode: _textFocus,
                              minLines: 1,
                              maxLines: 3,
                              style: const TextStyle(color: Colors.white),
                              cursorColor: AppTheme.primaryColor,
                              textInputAction: TextInputAction.send,
                              onSubmitted: (_) => _sendText(),
                              decoration: const InputDecoration(
                                hintText: '说点什么...',
                                hintStyle: TextStyle(color: Colors.white60),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '发送消息',
                            onPressed: state.isProcessing || state.isRecording
                                ? null
                                : _sendText,
                            icon: Icon(
                              Icons.arrow_upward,
                              color: state.isProcessing || state.isRecording
                                  ? Colors.white38
                                  : AppTheme.primaryColor,
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // 左侧键盘/语音切换按钮
                        _roundControl(
                          label: '打开键盘聊天',
                          icon: Icons.keyboard_alt_outlined,
                          iconColor: Colors.white70,
                          onTap: _toggleTyping,
                        ),

                        const SizedBox(width: 40),

                        // 中间语音按钮（长按录音，松手识别）
                        IgnorePointer(
                          ignoring: state.isCallActive,
                          child: Opacity(
                            opacity: state.isCallActive ? 0.45 : 1,
                            child: const _HomeVoiceButton(),
                          ),
                        ),

                        const SizedBox(width: 40),

                        _roundControl(
                          label: state.isCallActive ? '结束实时通话' : '开始实时通话',
                          icon: state.isCallActive
                              ? Icons.call_end
                              : Icons.call_outlined,
                          iconColor: state.isCallActive
                              ? Colors.redAccent
                              : AppTheme.primaryColor,
                          onTap: state.isCallActive
                              ? () => ref
                                    .read(digitalHumanProvider.notifier)
                                    .endCall()
                              : () => ref
                                    .read(digitalHumanProvider.notifier)
                                    .startCall(),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundControl({
    required String label,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.1),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: Icon(icon, color: iconColor, size: 24),
          ),
        ),
      ),
    );
  }

  /// 兜底动画：DUIX 不可用时显示呼吸动画头像
  Widget _buildFallbackAnimation() {
    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.95, end: 1.05),
        duration: const Duration(milliseconds: 3000),
        builder: (context, scale, child) {
          return Transform.scale(scale: scale, child: child);
        },
        child: Container(
          width: 160,
          height: 160,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppTheme.surfaceColor,
            border: Border.all(
              color: AppTheme.primaryColor.withValues(alpha: 0.3),
              width: 2,
            ),
          ),
          child: const Center(
            child: Text(
              'AI',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 48,
                fontWeight: FontWeight.w300,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 右上角图标按钮
  Widget _topIconButton(
    BuildContext context,
    IconData icon,
    String tooltip, {
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.black38,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: Icon(icon, color: Colors.white70, size: 20),
          ),
        ),
      ),
    );
  }
}

/// 首页语音按钮 — 按住录音，松手发送，上划取消
///
/// 行为：
/// - 按下 → 立即录音（打断当前TTS），零延迟
/// - 上滑超过阈值 → 取消录音
/// - 松手 → 停止录音 → ASR → LLM（简短回复）→ TTS 播报
class _HomeVoiceButton extends ConsumerStatefulWidget {
  const _HomeVoiceButton();

  @override
  ConsumerState<_HomeVoiceButton> createState() => _HomeVoiceButtonState();
}

class _HomeVoiceButtonState extends ConsumerState<_HomeVoiceButton>
    with SingleTickerProviderStateMixin {
  bool _isRecording = false;
  bool _isCancelling = false;
  double _dySinceStart = 0;
  double _startY = 0;

  static const double _cancelThreshold = 80.0;

  // Animation for the recording pulse
  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_isRecording) return;

    _startY = event.position.dy;
    setState(() {
      _isRecording = true;
      _isCancelling = false;
      _dySinceStart = 0;
    });
    _pulseController.repeat(reverse: true);

    ref.read(digitalHumanProvider.notifier).startVoiceInput();
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_isRecording) return;

    _dySinceStart = event.position.dy - _startY;

    if (_dySinceStart < -_cancelThreshold) {
      if (!_isCancelling) {
        setState(() => _isCancelling = true);
      }
    } else {
      if (_isCancelling) {
        setState(() => _isCancelling = false);
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (!_isRecording) return;

    final cancelled = _isCancelling || _dySinceStart < -_cancelThreshold;
    _pulseController.stop();
    _pulseController.reset();
    _resetState();

    if (cancelled) {
      ref.read(digitalHumanProvider.notifier).cancelVoiceInput();
    } else {
      ref.read(digitalHumanProvider.notifier).finishVoiceInput();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (!_isRecording) return;
    _pulseController.stop();
    _pulseController.reset();
    _resetState();
    ref.read(digitalHumanProvider.notifier).cancelVoiceInput();
  }

  void _resetState() {
    setState(() {
      _isRecording = false;
      _isCancelling = false;
      _dySinceStart = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Cancel hint
        if (_isCancelling)
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
              '松开取消',
              style: TextStyle(
                color: Colors.orangeAccent,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),

        // The button
        Semantics(
          button: true,
          label: _isRecording ? (_isCancelling ? '松开取消语音对话' : '正在录音') : '语音对话',
          hint: '按住录音，松手发送，上滑取消',
          child: Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUp,
            onPointerCancel: _onPointerCancel,
            child: _buildButton(),
          ),
        ),
      ],
    );
  }

  Widget _buildButton() {
    final scale = _isRecording ? _pulseAnimation.value : 1.0;

    Color bgColor;
    Color iconColor;
    IconData icon;

    if (_isCancelling) {
      bgColor = Colors.orange;
      iconColor = Colors.white;
      icon = Icons.keyboard_arrow_up;
    } else if (_isRecording) {
      bgColor = AppTheme.primaryColor;
      iconColor = Colors.white;
      icon = Icons.mic;
    } else {
      bgColor = AppTheme.primaryColor;
      iconColor = Colors.white;
      icon = Icons.mic_none;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: bgColor,
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryColor.withValues(alpha: 0.2),
            blurRadius: 20,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Transform.scale(
        scale: scale,
        child: Icon(icon, color: iconColor, size: 36),
      ),
    );
  }
}
