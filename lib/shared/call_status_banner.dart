import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/digital_human_provider.dart';

class CallStatusBanner extends ConsumerWidget {
  const CallStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      digitalHumanProvider.select((s) => s.isCallActive),
    );
    if (!active) return const SizedBox.shrink();
    return Positioned(
      left: 12,
      right: 12,
      top: MediaQuery.paddingOf(context).top + 6,
      child: Material(
        color: const Color(0xFF163A2B),
        borderRadius: BorderRadius.circular(8),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: () => context.go('/'),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.call, color: Color(0xFF00D56A), size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '实时通话中 · 返回助理',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '结束通话',
              onPressed: () =>
                  ref.read(digitalHumanProvider.notifier).endCall(),
              icon: const Icon(Icons.call_end, color: Colors.redAccent),
            ),
          ],
        ),
      ),
    );
  }
}
