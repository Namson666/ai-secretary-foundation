import 'package:flutter/material.dart';
import 'study_widgets.dart';

/// Displays domain facts even if the assistant's follow-up network request fails.
class StudyReceiptCard extends StatelessWidget {
  const StudyReceiptCard({
    super.key,
    required this.receipt,
    required this.undone,
    required this.undoPending,
    required this.enabled,
    required this.onUndo,
  });
  final Map<String, dynamic> receipt;
  final bool undone, undoPending, enabled;
  final VoidCallback? onUndo;
  @override
  Widget build(BuildContext context) {
    final committed = receipt['status'] == 'committed';
    final operation = receipt['operation_id'] as String?;
    final canUndo =
        committed &&
        receipt['undoable'] == true &&
        operation != null &&
        !undone;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xff1b2926),
        border: Border.all(color: studyTeal.withValues(alpha: .25)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                committed ? Icons.check_circle_outline : Icons.info_outline,
                size: 18,
                color: committed ? studyTeal : Colors.orangeAccent,
              ),
              const SizedBox(width: 8),
              Text(
                committed ? '操作已保存' : '操作结果',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            receipt['message'] as String,
            style: const TextStyle(height: 1.5),
          ),
          if (receipt['schedule_status'] == 'pending')
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '待安排 · 可在计划中确认时间',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
          if (undone)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                '本次贡献已撤销',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
          if (canUndo)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
                onPressed: !enabled || undoPending ? null : onUndo,
                child: Text(undoPending ? '正在撤销…' : '撤销本次保存'),
              ),
            ),
        ],
      ),
    );
  }
}
