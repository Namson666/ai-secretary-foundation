import 'package:flutter/material.dart';

import '../../../models/message.dart';
import '../../../services/llm_service.dart';
import '../../../shared/theme/app_theme.dart';

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isStreaming;

  const MessageBubble({
    super.key,
    required this.message,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: message.isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!message.isUser) _buildAvatar(),
          if (!message.isUser) const SizedBox(width: 8),
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: message.isUser
                    ? AppTheme.primaryColor
                    : AppTheme.surfaceColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: message.isUser
                      ? const Radius.circular(20)
                      : const Radius.circular(4),
                  bottomRight: message.isUser
                      ? const Radius.circular(4)
                      : const Radius.circular(20),
                ),
              ),
              child: _buildContent(),
            ),
          ),
          if (message.isUser) const SizedBox(width: 8),
          if (message.isUser) _buildAvatar(),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    return Container(
      width: 32,
      height: 32,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.surfaceColor,
      ),
      child: Center(
        child: Icon(
          message.isUser ? Icons.person : Icons.smart_toy_outlined,
          size: 18,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildContent() {
    final text = message.isAssistant
        ? LlmService.sanitizeAssistantContent(message.content)
        : message.content;

    if (text.isEmpty && isStreaming) {
      return _buildTypingIndicator();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: TextStyle(
            color: message.isUser ? Colors.white : AppTheme.textPrimary,
            fontSize: 15,
            height: 1.4,
          ),
        ),
        if (isStreaming) _buildCursor(),
        const SizedBox(height: 4),
        Text(
          _formatTime(message.createdAt),
          style: TextStyle(
            color: message.isUser
                ? Colors.white.withValues(alpha: 0.6)
                : AppTheme.textSecondary.withValues(alpha: 0.6),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildCursor() {
    return const Align(alignment: Alignment.centerLeft, child: _CursorWidget());
  }

  Widget _buildTypingIndicator() {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _TypingDot(delay: Duration.zero),
          const SizedBox(width: 4),
          _TypingDot(delay: const Duration(milliseconds: 300)),
          const SizedBox(width: 4),
          _TypingDot(delay: const Duration(milliseconds: 600)),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${time.month}/${time.day}';
  }
}

/// A blinking cursor shown at the end of streaming text.
class _CursorWidget extends StatefulWidget {
  const _CursorWidget();

  @override
  State<_CursorWidget> createState() => _CursorWidgetState();
}

class _CursorWidgetState extends State<_CursorWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: const Text(
        '|',
        style: TextStyle(
          color: AppTheme.primaryColor,
          fontSize: 15,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// An animated dot for the typing indicator.
class _TypingDot extends StatefulWidget {
  final Duration delay;

  const _TypingDot({required this.delay});

  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    Future.delayed(widget.delay, () {
      if (mounted) _controller.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }
}
