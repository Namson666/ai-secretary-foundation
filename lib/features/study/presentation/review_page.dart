import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../domain/study_service.dart';
import 'learning_page.dart';
import 'study_widgets.dart';

class StudyReviewPage extends ConsumerStatefulWidget {
  const StudyReviewPage({super.key});
  @override
  ConsumerState<StudyReviewPage> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<StudyReviewPage> {
  String filter = '待安排';
  final operations = <String, String>{};
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studyControllerProvider).asData?.value;
    final catalog = ref.watch(studyCatalogProvider).asData?.value;
    if (state == null || catalog == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final status = switch (filter) {
      '待安排' => 'pending',
      '已安排' => 'planned',
      '已完成' => 'done',
      _ => 'cancelled',
    };
    final rows = state.reviews.where((r) => r.status == status).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('复习点')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const Text(
            '保存与安排分开',
            style: TextStyle(fontSize: 27, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          const Text(
            '收录会产生真实本地提交回执。等待安排的任务不会混入今日到期队列。',
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            children: ['待安排', '已安排', '已完成', '已撤销']
                .map(
                  (s) => ChoiceChip(
                    label: Text(s),
                    selected: filter == s,
                    onSelected: (_) => setState(() => filter = s),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 18),
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 45),
              child: Text(
                '这里还没有复习点。\n在词卡或AI对话里提出收录。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ...rows.map(
            (point) => Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      catalog.words[point.wordId]!.word,
                      style: const TextStyle(fontSize: 23),
                    ),
                    Text(
                      '${skillLabel(point.skill)} · ${chinaTime(point.dueAt)}',
                      style: const TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 12),
                    if (point.status == 'pending')
                      FilledButton(
                        onPressed: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: DateTime.now().add(
                              const Duration(days: 1),
                            ),
                            firstDate: DateTime.now(),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365),
                            ),
                          );
                          if (picked == null || !context.mounted) return;
                          final due = DateTime.utc(
                            picked.year,
                            picked.month,
                            picked.day,
                            11,
                            30,
                          );
                          if (due.isBefore(DateTime.now().toUtc())) {
                            studyMessage(context, '该日19:30已过，请选择未来时间。');
                            return;
                          }
                          await studyCommit(
                            context,
                            ref,
                            (r) => r.schedule(
                              studyCommandId(),
                              point.id,
                              due,
                              expectedRevision: point.revision,
                            ),
                          );
                        },
                        child: const Text('安排日期 · 19:30'),
                      ),
                    if (point.status == 'planned')
                      OutlinedButton(
                        onPressed: () => studyOpen(
                          context,
                          StudyLearningPage(
                            tasks: [
                              StudyTask(
                                point.wordId,
                                point.skill,
                                reviewId: point.id,
                              ),
                            ],
                          ),
                        ),
                        child: const Text('开始专项练习'),
                      ),
                    if (point.status == 'done')
                      const Text(
                        '完成记录保留，不由撤销删除。',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
