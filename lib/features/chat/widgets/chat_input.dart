import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_theme.dart';
import '../widgets/voice_button.dart';

class ChatInput extends ConsumerStatefulWidget {
  const ChatInput({super.key});

  @override
  ConsumerState<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends ConsumerState<ChatInput> {
  final _textController = TextEditingController();
  bool _hasContent = false;
  String? _voiceDraft;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasContent = _textController.text.trim().isNotEmpty;
    if (hasContent != _hasContent) {
      setState(() => _hasContent = hasContent);
    }
  }

  void _sendMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    ref.read(chatProvider.notifier).sendMessage(text);
    _textController.clear();
  }

  @override
  Widget build(BuildContext context) {
    final isStreaming = ref.watch(chatProvider.select((s) => s.isStreaming));

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
      decoration: const BoxDecoration(
        color: AppTheme.backgroundColor,
        border: Border(
          top: BorderSide(color: AppTheme.surfaceColor, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // Voice button
            VoiceButton(
              onPartial: (text) {
                _voiceDraft ??= _textController.text;
                _textController.value = TextEditingValue(
                  text: text,
                  selection: TextSelection.collapsed(offset: text.length),
                );
              },
              onResult: (text) {
                _textController.text = _voiceDraft ?? '';
                _voiceDraft = null;
                ref.read(chatProvider.notifier).sendMessage(text);
              },
              onCancel: () {
                if (_voiceDraft == null) return;
                _textController.text = _voiceDraft!;
                _voiceDraft = null;
              },
            ),
            const SizedBox(width: 8),
            // Text input
            Expanded(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceColor,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: TextField(
                  controller: _textController,
                  maxLines: 1,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  enabled: true,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                  ),
                  decoration: InputDecoration(
                    hintText: isStreaming ? 'AI 思考中，可继续输入' : '输入消息...',
                    hintStyle: TextStyle(
                      color: AppTheme.textSecondary.withValues(alpha: 0.5),
                      fontSize: 15,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Send button
            Semantics(
              container: true,
              button: true,
              enabled: _hasContent && !isStreaming,
              label: '发送消息',
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _hasContent && !isStreaming
                      ? AppTheme.primaryColor
                      : AppTheme.surfaceColor,
                ),
                child: IconButton(
                  tooltip: '发送消息',
                  icon: Icon(
                    Icons.arrow_upward,
                    color: _hasContent && !isStreaming
                        ? Colors.white
                        : AppTheme.textSecondary,
                    size: 20,
                  ),
                  onPressed: (_hasContent && !isStreaming)
                      ? _sendMessage
                      : null,
                  padding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
