import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_theme.dart';
import '../widgets/chat_input.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends ConsumerStatefulWidget {
  final String? sessionId;
  final String? initialVoiceText;

  const ChatScreen({super.key, this.sessionId, this.initialVoiceText});

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollController = ScrollController();
  bool _isLoadingHistory = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _handleInitialVoiceText();
  }

  void _handleInitialVoiceText() {
    // Check widget parameter first, then fall back to provider
    final inputText =
        widget.initialVoiceText ?? ref.read(initialVoiceTextProvider);
    if (inputText != null && inputText.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(chatProvider.notifier).sendMessage(inputText);
          ref.read(initialVoiceTextProvider.notifier).setText(null);
        }
      });
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      if (widget.sessionId != null) {
        await ref
            .read(chatProvider.notifier)
            .switchToSession(widget.sessionId!);
      } else {
        await ref.read(chatProvider.notifier).loadTodaySession();
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingHistory = false);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatProvider);
    final messages = state.messages;

    // Auto-scroll when messages change
    if (messages.isNotEmpty) {
      _scrollToBottom();
    }

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundColor,
        elevation: 0,
        leading: IconButton(
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '数字人底座',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: const [],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: _isLoadingHistory
                ? const Center(child: CircularProgressIndicator())
                : messages.isEmpty
                ? _buildEmptyState()
                : _buildMessageList(messages),
          ),
          // Error banner
          if (state.error != null) _buildErrorBanner(state.error!),
          // Input bar
          const ChatInput(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: AppTheme.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          const Text(
            '今天还没有对话',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Text(
          '这里会持续保存今天的对话',
            style: TextStyle(
              color: AppTheme.textSecondary.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(List<dynamic> messages) {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final isLast = index == messages.length - 1;
        final isStreaming =
            isLast &&
            message.isAssistant &&
            ref.watch(chatProvider.select((s) => s.isStreaming));

        return MessageBubble(message: message, isStreaming: isStreaming);
      },
    );
  }

  Widget _buildErrorBanner(String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.red.withValues(alpha: 0.1),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: '关闭错误提示',
            icon: const Icon(Icons.close, color: Colors.red, size: 16),
            onPressed: () {
              ref.read(chatProvider.notifier).clearError();
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }
}
