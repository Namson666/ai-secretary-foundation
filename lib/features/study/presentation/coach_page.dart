import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../study_runtime/study_avatar.dart';
import '../../study_runtime/study_conversation_runtime.dart';
import '../application/study_providers.dart';
import '../application/study_tools.dart';
import '../application/study_runtime_provider.dart';
import 'study_widgets.dart';
import 'study_receipt_card.dart';

class StudyCoachPage extends ConsumerStatefulWidget {
  final bool active;
  const StudyCoachPage({super.key, required this.active});
  @override
  ConsumerState<StudyCoachPage> createState() => _StudyCoachPageState();
}

class _StudyCoachPageState extends ConsumerState<StudyCoachPage> {
  final _text = TextEditingController();
  final _messages = ScrollController();
  final _avatarKey = GlobalKey();
  final _holdFocus = FocusNode();
  OverlayEntry? _fullscreen;
  bool _video = false;
  bool _typing = false;
  int? _pointer;
  double _startY = 0;
  bool _cancelGesture = false;
  bool _keyboardHolding = false;
  int _messageCount = 0;
  int _receiptEpoch = 0;
  final _receiptActions = <Map<String, dynamic>>[];
  final _undoPending = <String>{};
  final _undone = <String>{};
  DateTime? _holdStarted;
  Timer? _holdTicker;
  late StudyConversationRuntime _runtime;

  @override
  void initState() {
    super.initState();
    _runtime = ref.read(studyRuntimeProvider);
    _runtime.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    if (_messageCount != _runtime.messages.length) {
      _messageCount = _runtime.messages.length;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _messages.hasClients) {
          _messages.animateTo(
            _messages.position.maxScrollExtent,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          );
        }
      });
    }
    setState(() {});
    _fullscreen?.markNeedsBuild();
  }

  @override
  void didUpdateWidget(StudyCoachPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      ++_receiptEpoch;
      _leaveFullscreen();
      _resetHold();
      unawaited(_runtime.endCall());
      unawaited(_runtime.cancelHold());
    }
  }

  @override
  void dispose() {
    ++_receiptEpoch;
    _runtime.removeListener(_changed);
    _holdTicker?.cancel();
    unawaited(_runtime.endCall());
    unawaited(_runtime.cancelHold());
    _fullscreen?.remove();
    _fullscreen?.dispose();
    _fullscreen = null;
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    _text.dispose();
    _messages.dispose();
    _holdFocus.dispose();
    super.dispose();
  }

  void _resetHold() {
    _holdTicker?.cancel();
    _holdTicker = null;
    _holdStarted = null;
    _pointer = null;
    _keyboardHolding = false;
    _cancelGesture = false;
  }

  void _cancelHold() {
    _resetHold();
    unawaited(_runtime.cancelHold());
    if (mounted) setState(() {});
  }

  void _startHold() {
    if (_runtime.busy || _runtime.callActive || !widget.active) return;
    _holdStarted = DateTime.now();
    _holdTicker?.cancel();
    _holdTicker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || _runtime.phase != StudyConversationPhase.recording) {
        _holdTicker?.cancel();
        return;
      }
      setState(() {});
    });
    unawaited(_runtime.startHold());
  }

  void _finishHold() {
    final cancelled = _cancelGesture;
    _resetHold();
    if (cancelled) {
      unawaited(_runtime.cancelHold());
    } else {
      unawaited(_runtime.finishHold());
    }
    setState(() {});
  }

  KeyEventResult _holdKey(FocusNode node, KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelHold();
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.space &&
        event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent && !_keyboardHolding) {
      _keyboardHolding = true;
      _startHold();
    }
    if (event is KeyUpEvent && _keyboardHolding) _finishHold();
    return KeyEventResult.handled;
  }

  Future<void> _setVideo(bool value) async {
    if (value == _video) return;
    _cancelHold();
    if (!value) {
      _leaveFullscreen();
      await _runtime.endCall();
    }
    if (mounted) setState(() => _video = value);
  }

  void _enterFullscreen() {
    if (_fullscreen != null || !_runtime.callActive || !widget.active) return;
    FocusManager.instance.primaryFocus?.unfocus();
    // Reparent the single GlobalKey avatar in the same frame: no second native
    // renderer, no disposal or call/audio restart on expand/shrink.
    _fullscreen = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: Material(
          color: const Color(0xff080b10),
          child: SafeArea(top: false, child: _callScene(fullscreen: true)),
        ),
      ),
    );
    setState(() {});
    Overlay.of(context, rootOverlay: true).insert(_fullscreen!);
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
  }

  void _leaveFullscreen() {
    final entry = _fullscreen;
    if (entry == null) return;
    _fullscreen = null;
    entry.remove();
    entry.dispose();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    if (mounted) setState(() {});
  }

  Future<void> _hangup() async {
    _leaveFullscreen();
    await _runtime.endCall();
  }

  Widget _avatar() => StudyAvatar(
    key: _avatarKey,
    isSpeaking: _runtime.phase == StudyConversationPhase.speaking,
  );

  String get _status => switch (_runtime.phase) {
    StudyConversationPhase.recording =>
      _cancelGesture
          ? '松开取消'
          : '录音 ${DateTime.now().difference(_holdStarted ?? DateTime.now()).inSeconds}s · 上滑取消',
    StudyConversationPhase.transcribing => '正在识别语音',
    StudyConversationPhase.thinking => '正在组织回复',
    StudyConversationPhase.speaking => '正在说话',
    StudyConversationPhase.listening => _runtime.muted ? '麦克风已静音' : '正在听你说话',
    StudyConversationPhase.idle => _runtime.callActive ? '麦克风已静音' : '随时开始对话',
  };
  String get _timer =>
      '${_runtime.elapsed.inMinutes.toString().padLeft(2, '0')}:${(_runtime.elapsed.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final focus = ref.watch(studyFocusProvider);
    final word = focus == null
        ? null
        : ref.watch(studyCatalogProvider).asData?.value.words[focus];
    return PopScope(
      canPop: _fullscreen == null,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leaveFullscreen();
      },
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'AI 伙伴',
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '发音评测未启用',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.chat_bubble_outline, size: 18),
                    label: Text('普通对话'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.videocam_outlined, size: 20),
                    label: Text('实时通话'),
                  ),
                ],
                selected: {_video},
                showSelectedIcon: false,
                onSelectionChanged: (value) =>
                    unawaited(_setVideo(value.single)),
              ),
              const SizedBox(height: 12),
              if (word != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.bookmark_outline,
                        size: 16,
                        color: studyTeal,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '当前词 · ${word.word}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: studyTeal,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '清除当前词焦点',
                        onPressed: () =>
                            ref.read(studyFocusProvider.notifier).set(null),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              if (_video)
                Expanded(
                  child: _fullscreen == null
                      ? _callScene(fullscreen: false)
                      : const SizedBox.expand(),
                )
              else ...[
                Expanded(
                  flex: 5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: _fullscreen == null
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              if (widget.active) _avatar(),
                              Positioned(
                                left: 14,
                                bottom: 14,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 7,
                                    ),
                                    child: Text(
                                      _status,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.expand(),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(flex: 5, child: _chatMessages()),
                if (_runtime.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Text(
                      _runtime.error!,
                      style: const TextStyle(
                        color: Color(0xfff5b28c),
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (_runtime.partial.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      _runtime.partial,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: studyTeal, fontSize: 12),
                    ),
                  ),
                _composer(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _chatMessages() {
    final receipts = [..._runtime.toolReceipts, ..._receiptActions]
        .where(
          (r) => r['message'] is String && (r['message'] as String).isNotEmpty,
        )
        .toList();
    if (_runtime.messages.isEmpty && receipts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(18),
          child: Text(
            '聊聊今天，或一起练英语。\n按住说话，松开发送；也可以输入文字。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54, height: 1.7, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      controller: _messages,
      itemCount: _runtime.messages.length + receipts.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index >= _runtime.messages.length) {
          return _receiptCard(receipts[index - _runtime.messages.length]);
        }
        final message = _runtime.messages[index];
        return Align(
          alignment: message.isUser
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * .77,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: message.isUser
                  ? const Color(0xff263b34)
                  : const Color(0xff20252c),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '${message.isVoice ? '♪  ' : ''}${message.text}',
              style: const TextStyle(
                color: Color(0xfff2f3f5),
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _undoReceipt(String operation) async {
    if (_undoPending.contains(operation) || _runtime.busy) return;
    final epoch = _receiptEpoch;
    setState(() => _undoPending.add(operation));
    try {
      final tools = await ref.read(studyToolsProvider.future);
      final receipt = await tools.invoke(
        'study_review_point_undo',
        {'operation_id': operation},
        StudyToolContext(
          commandId: studyCommandId(),
          userText: '撤销这条复习贡献 $operation',
          isCurrent: () => mounted && widget.active && epoch == _receiptEpoch,
        ),
      );
      if (!mounted) return;
      setState(() {
        _receiptActions.add(receipt);
        if (receipt['status'] == 'committed') _undone.add(operation);
      });
      // Refreshing the display cannot undo a transaction that already committed.
      await ref.read(studyControllerProvider.notifier).refresh();
    } catch (_) {
      if (mounted) studyMessage(context, '暂时无法撤销，请重试；原保存结果仍保留。');
    } finally {
      if (mounted) setState(() => _undoPending.remove(operation));
    }
  }

  Widget _receiptCard(Map<String, dynamic> receipt) {
    final operation = receipt['operation_id'] as String?;
    return StudyReceiptCard(
      receipt: receipt,
      undone:
          _undone.contains(operation) ||
          [..._runtime.toolReceipts, ..._receiptActions].any(
            (r) =>
                r['status'] == 'committed' &&
                r['reverted_operation_id'] == operation,
          ),
      undoPending: _undoPending.contains(operation),
      enabled: !_runtime.busy,
      onUndo: operation == null ? null : () => _undoReceipt(operation),
    );
  }

  Widget _composer() => Row(
    children: [
      IconButton(
        tooltip: _typing ? '切换按住说话' : '切换文字输入',
        onPressed: () {
          _cancelHold();
          setState(() => _typing = !_typing);
        },
        icon: Icon(_typing ? Icons.mic_none : Icons.keyboard_outlined),
      ),
      Expanded(
        child: _typing
            ? TextField(
                controller: _text,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '发消息…',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
                onSubmitted: (_) => _sendText(),
              )
            : Focus(
                focusNode: _holdFocus,
                onKeyEvent: _holdKey,
                onFocusChange: (hasFocus) {
                  if (!hasFocus && (_pointer != null || _keyboardHolding)) {
                    _cancelHold();
                  }
                },
                child: Semantics(
                  button: true,
                  label: '按住说话，松开发送，上滑取消。键盘按住空格键。',
                  onTap: () {
                    if (_runtime.phase == StudyConversationPhase.recording) {
                      _finishHold();
                    } else {
                      _startHold();
                    }
                  },
                  onLongPress: () => studyMessage(context, '按住按钮后松开发送，或切换文字输入'),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) {
                      if (event.buttons != 1 ||
                          _pointer != null ||
                          _runtime.busy) {
                        return;
                      }
                      _pointer = event.pointer;
                      _startY = event.position.dy;
                      _cancelGesture = false;
                      _holdFocus.requestFocus();
                      _startHold();
                    },
                    onPointerMove: (event) {
                      if (event.pointer != _pointer) return;
                      setState(
                        () => _cancelGesture = _startY - event.position.dy > 64,
                      );
                    },
                    onPointerUp: (event) {
                      if (event.pointer == _pointer) _finishHold();
                    },
                    onPointerCancel: (event) {
                      if (event.pointer == _pointer) _cancelHold();
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      height: 52,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _cancelGesture
                            ? const Color(0xff652b32)
                            : _runtime.phase == StudyConversationPhase.recording
                            ? const Color(0xff285c49)
                            : const Color(0xff242a32),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _runtime.phase == StudyConversationPhase.recording
                            ? _status
                            : '按住说话',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
      if (_typing)
        IconButton(
          tooltip: '发送消息',
          onPressed: _runtime.busy ? null : _sendText,
          icon: const Icon(Icons.arrow_upward_rounded, color: studyTeal),
        ),
    ],
  );
  void _sendText() {
    final value = _text.text.trim();
    if (value.isEmpty || _runtime.busy) return;
    _text.clear();
    unawaited(_runtime.sendText(value));
  }

  Widget _roundControl({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    bool end = false,
  }) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox(
        width: 64,
        height: 64,
        child: IconButton.filled(
          tooltip: label,
          onPressed: onTap,
          style: IconButton.styleFrom(
            backgroundColor: end
                ? const Color(0xffec4d58)
                : active
                ? Colors.white
                : const Color(0xff30353c),
            foregroundColor: end || !active
                ? Colors.white
                : const Color(0xff11151a),
          ),
          icon: Icon(icon, size: 27),
        ),
      ),
      const SizedBox(height: 9),
      Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
    ],
  );

  Widget _callScene({required bool fullscreen}) {
    final active = _runtime.callActive;
    return ClipRRect(
      borderRadius: BorderRadius.circular(fullscreen ? 0 : 22),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.active) _avatar(),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x80000000),
                  Colors.transparent,
                  Color(0xe6000000),
                ],
                stops: [0, .48, 1],
              ),
            ),
          ),
          Positioned(
            top: fullscreen ? MediaQuery.paddingOf(context).top + 18 : 16,
            left: 18,
            right: 12,
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '拾语 · 实时对话',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        active ? '$_timer · $_status' : '准备好，聊一会儿',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (active)
                  IconButton(
                    tooltip: fullscreen ? '收起全屏' : '数字人全屏',
                    onPressed: fullscreen ? _leaveFullscreen : _enterFullscreen,
                    icon: Icon(
                      fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: fullscreen ? 138 : 130,
            child: Column(
              children: [
                if (_runtime.error != null)
                  Text(
                    _runtime.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xffffbc9f),
                      fontSize: 13,
                    ),
                  ),
                if (_runtime.partial.isNotEmpty)
                  Text(
                    _runtime.partial,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      height: 1.4,
                    ),
                  )
                else if (_runtime.messages.isNotEmpty)
                  Text(
                    _runtime.messages.last.text,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      height: 1.4,
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            bottom: 24,
            child: active
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _roundControl(
                        label: _runtime.speakerEnabled ? '音频开启' : '音频关闭',
                        icon: _runtime.speakerEnabled
                            ? Icons.volume_up
                            : Icons.volume_off,
                        active: _runtime.speakerEnabled,
                        onTap: () => unawaited(
                          _runtime.setSpeaker(!_runtime.speakerEnabled),
                        ),
                      ),
                      _roundControl(
                        label: '结束',
                        icon: Icons.call_end,
                        end: true,
                        onTap: () => unawaited(_hangup()),
                      ),
                      _roundControl(
                        label: _runtime.muted ? '取消静音' : '静音',
                        icon: _runtime.muted ? Icons.mic_off : Icons.mic,
                        active: _runtime.muted,
                        onTap: () =>
                            unawaited(_runtime.setMuted(!_runtime.muted)),
                      ),
                    ],
                  )
                : Center(
                    child: SizedBox(
                      width: 76,
                      height: 76,
                      child: IconButton.filled(
                        tooltip: '开始实时语音通话',
                        onPressed: () => unawaited(_runtime.startCall()),
                        style: IconButton.styleFrom(
                          backgroundColor: studyTeal,
                          foregroundColor: Colors.black,
                        ),
                        icon: const Icon(Icons.call, size: 30),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
