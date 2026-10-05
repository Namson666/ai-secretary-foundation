import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../domain/study_service.dart';
import 'study_widgets.dart';
import 'learning_page.dart';
import 'plan_page.dart';
import 'review_page.dart';
import 'exam_page.dart';

class StudyHomePage extends ConsumerWidget {
  const StudyHomePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(studyControllerProvider).asData?.value;
    final catalog = ref.watch(studyCatalogProvider).asData?.value;
    if (state == null || catalog == null) return const SizedBox.shrink();
    final service = ref.watch(studyServiceProvider).asData?.value;
    final queue = service?.dailyQueue(state) ?? <StudyTask>[];
    final due = queue.where((t) => t.reviewId != null).length;
    final book = catalog.books.firstWhere(
      (b) => b.id == state.preferences.bookId,
    );
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const Text(
            '拾语 / DAILY',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 12,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '今日学习',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 25),
          Row(
            children: [
              Expanded(child: Text(book.title)),
              Text(
                '${state.preferences.dailyLimit} 词 / 天',
                style: const TextStyle(color: studyTeal),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            '${state.todayAttempts}',
            style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w500),
          ),
          const Text('今天的真实练习尝试', style: TextStyle(color: Colors.white60)),
          const SizedBox(height: 12),
          Card(
            child: Row(
              children: [
                StudyMetric('优先复习', '$due', detail: '个到期任务'),
                StudyMetric('可以新学', '${queue.length - due}', detail: '个所选新词'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: queue.isEmpty
                ? null
                : () => studyOpen(context, StudyLearningPage(tasks: queue)),
            icon: const Icon(Icons.arrow_forward),
            label: const Padding(
              padding: EdgeInsets.all(14),
              child: Text('开始学习'),
            ),
          ),
          if (state.session != null)
            TextButton(
              onPressed: () =>
                  studyOpen(context, const StudyLearningPage.resume()),
              child: const Text('继续上次学习'),
            ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${state.preferences.budgetMinutes} 分钟预算',
                style: const TextStyle(color: Colors.white54),
              ),
              TextButton.icon(
                onPressed: () => studyCommit(
                  context,
                  ref,
                  (r) => r.updatePreferences(studyCommandId(), {
                    'quiet': !state.preferences.quiet,
                  }, expectedRevision: state.preferences.revision),
                ),
                icon: Icon(
                  state.preferences.quiet ? Icons.volume_off : Icons.volume_up,
                  size: 18,
                ),
                label: Text(state.preferences.quiet ? '静音学习' : '可以开口'),
              ),
            ],
          ),
          const StudySection('学习工具'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: () => studyOpen(context, const StudyReviewPage()),
                icon: const Icon(Icons.history),
                label: const Text('复习点'),
              ),
              OutlinedButton.icon(
                onPressed: () => studyOpen(context, const StudyPlanPage()),
                icon: const Icon(Icons.event_note),
                label: const Text('学习计划'),
              ),
              OutlinedButton.icon(
                onPressed: () => studyOpen(context, const StudyExamPage()),
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('阶段考试'),
              ),
            ],
          ),
          const StudySection('接下来'),
          ...state.reviews
              .where((r) => r.status == 'pending' || r.status == 'planned')
              .take(5)
              .map(
                (r) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${catalog.words[r.wordId]?.word} · ${skillLabel(r.skill)}',
                  ),
                  subtitle: Text(
                    r.status == 'pending' ? '已保存，等待安排' : chinaTime(r.dueAt),
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => studyOpen(context, const StudyReviewPage()),
                ),
              ),
          if (queue.isEmpty)
            const Text(
              '今天没有可执行任务。去选词，或调整新学上限。',
              style: TextStyle(color: Colors.white54),
            ),
          const SizedBox(height: 18),
          const Text(
            '本地学习记录真实保存。发音增强关闭时，基础学习仍可继续。',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
