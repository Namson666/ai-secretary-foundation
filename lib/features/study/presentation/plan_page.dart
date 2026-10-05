import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import 'study_widgets.dart';

class StudyPlanPage extends ConsumerStatefulWidget {
  const StudyPlanPage({super.key});
  @override
  ConsumerState<StudyPlanPage> createState() => _PlanState();
}

class _PlanState extends ConsumerState<StudyPlanPage> {
  Map<String, dynamic>? draft;
  int? revision;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studyControllerProvider).asData?.value;
    if (state == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    draft ??= {
      'dailyLimit': state.preferences.dailyLimit,
      'newLimit': state.preferences.newLimit,
      'budgetMinutes': state.preferences.budgetMinutes,
      'direction': state.preferences.direction,
      'order': state.preferences.order,
      'mode': state.preferences.mode,
    };
    revision ??= state.preferences.revision;
    return Scaffold(
      appBar: AppBar(title: const Text('学习计划')),
      body: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          const Text(
            '按照你的节奏',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text(
            '每日学习量包含复习和新学。优先到期复习；保守按每任务3分钟安排，已完成尝试扣除当天额度。',
            style: TextStyle(color: Colors.white54, height: 1.6),
          ),
          const StudySection('每日预算'),
          _field('总学习量', 'dailyLimit', [10, 20, 30, 50, 80], suffix: '词'),
          _field('最多新学', 'newLimit', [0, 5, 10, 20, 30], suffix: '词'),
          _field('时间预算', 'budgetMinutes', [10, 20, 30, 45], suffix: '分钟'),
          const StudySection('默认训练'),
          _field(
            '记忆方向',
            'direction',
            ['en-cn', 'cn-en', 'spell', 'listen'],
            labels: const {
              'en-cn': '英文猜中文',
              'cn-en': '中文猜英文',
              'spell': '拼写',
              'listen': '听辨',
            },
          ),
          _field(
            '选词顺序',
            'order',
            ['book', 'random', 'review'],
            labels: const {'book': '词书顺序', 'random': '随机新词', 'review': '优先复习'},
          ),
          _field(
            'Agent模式',
            'mode',
            ['manual', 'assisted', 'managed'],
            labels: const {
              'manual': '手动',
              'assisted': 'AI辅助建议',
              'managed': '预算内托管',
            },
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              final receipt = await studyCommit(
                context,
                ref,
                (r) => r.updatePreferences(
                  studyCommandId(),
                  draft!,
                  expectedRevision: revision!,
                ),
              );
              if (receipt != null && mounted) {
                setState(() => revision = receipt.values['revision'] as int);
              }
            },
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('保存并应用计划'),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            '时区：上海（UTC+8）\nAI建议必须确认，旧版本草案不能覆盖新计划。调整计划保留历史。',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    String key,
    List<Object> values, {
    String suffix = '',
    Map<String, String> labels = const {},
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        DropdownButton<Object>(
          key: ValueKey('plan-$key'),
          value: draft![key],
          items: values
              .map(
                (v) => DropdownMenuItem(
                  value: v,
                  child: Text(labels['$v'] ?? '$v $suffix'),
                ),
              )
              .toList(),
          onChanged: (v) => setState(() => draft![key] = v),
        ),
      ],
    ),
  );
}
