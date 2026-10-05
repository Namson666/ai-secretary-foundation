import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../domain/study_models.dart';
import '../domain/study_repository.dart';

const studyTeal = Color(0xff4fbfa4);
String skillLabel(StudySkill skill) => switch (skill) {
  StudySkill.meaning => '英→中回忆',
  StudySkill.production => '中→英回忆',
  StudySkill.spelling => '拼写',
  StudySkill.listening => '听辨',
  StudySkill.pronunciation => '发音',
};
String chinaTime(DateTime? date) {
  if (date == null) return '待安排';
  final local = date.toUtc().add(const Duration(hours: 8));
  return '${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

void studyMessage(BuildContext context, String text) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

Future<CommitReceipt?> studyCommit(
  BuildContext context,
  WidgetRef ref,
  Future<CommitReceipt> Function(StudyRepository) action,
) async {
  try {
    final receipt = await ref
        .read(studyControllerProvider.notifier)
        .commit(action);
    if (context.mounted) studyMessage(context, receipt.message);
    return receipt;
  } catch (error) {
    if (context.mounted) {
      studyMessage(
        context,
        error is StudyFailure ? error.message : '保存失败，请重试；没有报告为已保存。',
      );
    }
    return null;
  }
}

void studyOpen(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

class StudySection extends StatelessWidget {
  const StudySection(this.title, {super.key, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class StudyMetric extends StatelessWidget {
  const StudyMetric(this.label, this.value, {super.key, this.detail = ''});
  final String label, value, detail;
  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600),
          ),
          if (detail.isNotEmpty)
            Text(
              detail,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
        ],
      ),
    ),
  );
}

class StudyTextDialog extends StatefulWidget {
  const StudyTextDialog({
    super.key,
    required this.title,
    required this.hint,
    required this.confirm,
    this.initial = '',
    this.maxLines = 5,
    this.maxLength,
  });
  final String title, hint, confirm, initial;
  final int maxLines;
  final int? maxLength;
  @override
  State<StudyTextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<StudyTextDialog> {
  late final TextEditingController input = TextEditingController(
    text: widget.initial,
  );
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 340,
      child: TextField(
        controller: input,
        maxLines: widget.maxLines,
        maxLength: widget.maxLength,
        decoration: InputDecoration(hintText: widget.hint),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, input.text),
        child: Text(widget.confirm),
      ),
    ],
  );
}
