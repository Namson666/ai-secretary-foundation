import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../providers/chat_provider.dart';
import '../../../shared/theme/app_theme.dart';
import 'chat_screen.dart';

class ChatHistorySheet extends ConsumerStatefulWidget {
  const ChatHistorySheet({super.key});

  @override
  ConsumerState<ChatHistorySheet> createState() => _ChatHistorySheetState();
}

class _ChatHistorySheetState extends ConsumerState<ChatHistorySheet> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(chatProvider.notifier).loadHistorySessions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(chatProvider.select((s) => s.historySessions));

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.backgroundColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.textSecondary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Title bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Chat History',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  tooltip: '关闭聊天记录',
                  icon: const Icon(Icons.close, color: AppTheme.textSecondary),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          const Divider(color: AppTheme.surfaceColor, height: 1),

          // Session list
          Flexible(
            child: sessions.isEmpty
                ? _buildEmptyHistory()
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => const Divider(
                      color: AppTheme.surfaceColor,
                      height: 1,
                      indent: 20,
                      endIndent: 20,
                    ),
                    itemBuilder: (context, index) {
                      final session = sessions[index];
                      return _buildSessionItem(context, session);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyHistory() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          Icon(
            Icons.history,
            size: 48,
            color: AppTheme.textSecondary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 12),
          const Text(
            'No chat history yet',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionItem(BuildContext context, Map<String, dynamic> session) {
    final sessionId = session['session_id'] as String? ?? '';
    final lastTimeStr = session['last_time'] as String?;
    final lastContent = session['last_content'] as String? ?? '(empty)';
    final messageCount = session['message_count'] as int? ?? 0;

    DateTime? lastTime;
    if (lastTimeStr != null) {
      lastTime = DateTime.tryParse(lastTimeStr);
    }

    final timeText = lastTime != null
        ? DateFormat('MM/dd HH:mm').format(lastTime)
        : '';

    final preview = lastContent.length > 60
        ? '${lastContent.substring(0, 60)}...'
        : lastContent;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      title: Text(
        preview,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 12,
              color: AppTheme.textSecondary.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 4),
            Text(
              '$messageCount messages',
              style: TextStyle(
                color: AppTheme.textSecondary.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
            if (timeText.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                timeText,
                style: TextStyle(
                  color: AppTheme.textSecondary.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      trailing: const Icon(
        Icons.chevron_right,
        color: AppTheme.textSecondary,
        size: 20,
      ),
      onTap: () {
        Navigator.of(context).pop(); // Close bottom sheet
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ChatScreen(sessionId: sessionId)),
        );
      },
    );
  }
}
