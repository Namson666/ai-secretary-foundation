import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../domain/study_models.dart';
import '../domain/study_analytics.dart';
import 'study_widgets.dart';

class StudyStatisticsPage extends ConsumerStatefulWidget {
  const StudyStatisticsPage({super.key});
  @override
  ConsumerState<StudyStatisticsPage> createState() => _StatisticsState();
}

class _StatisticsState extends ConsumerState<StudyStatisticsPage> {
  int tab = 0;
  int days = 7;
  StudySkill? skill;
  @override
  Widget build(BuildContext context) {
    final value = ref.watch(studyControllerProvider);
    final analytics = ref.watch(studyAnalyticsProvider);
    return SafeArea(
      child: value.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: TextButton(
            onPressed: () => ref.invalidate(studyControllerProvider),
            child: const Text('统计读取失败，点击重试'),
          ),
        ),
        data: (state) => ListView(
          padding: const EdgeInsets.all(22),
          children: [
            const Text(
              '学习统计',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text(
              '每一次回忆，都留下真实记录。',
              style: TextStyle(color: Colors.white54),
            ),
            const SizedBox(height: 24),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('记忆预测')),
                ButtonSegment(value: 1, label: Text('学习情况')),
                ButtonSegment(value: 2, label: Text('技能进展')),
              ],
              selected: {tab},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => tab = v.single),
            ),
            const SizedBox(height: 22),
            if (tab != 1)
              Align(
                alignment: Alignment.centerLeft,
                child: PopupMenuButton<String>(
                  initialValue: skill?.name ?? 'all',
                  onSelected: (v) => setState(
                    () =>
                        skill = v == 'all' ? null : StudySkill.values.byName(v),
                  ),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'all', child: Text('全部技能')),
                    ...StudySkill.values.map(
                      (s) => PopupMenuItem(
                        value: s.name,
                        child: Text(skillLabel(s)),
                      ),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          skill == null ? '全部技能' : skillLabel(skill!),
                          style: const TextStyle(color: studyTeal),
                        ),
                        const Icon(Icons.expand_more, color: studyTeal),
                      ],
                    ),
                  ),
                ),
              ),
            if (tab == 0) ...[
              _analytics(analytics, _forecast),
              const StudySection('复习安排'),
              Row(
                children: [
                  StudyMetric(
                    '已安排',
                    '${state.reviews.where((r) => r.status == 'planned').length}',
                    detail: '个复习点',
                  ),
                  StudyMetric(
                    '待安排',
                    '${state.reviews.where((r) => r.status == 'pending').length}',
                    detail: '已保存的复习点',
                  ),
                ],
              ),
            ],
            if (tab == 1) ...[
              const StudySection('练习活动'),
              Row(
                children: [
                  StudyMetric('今天', '${state.todayAttempts}', detail: '次练习'),
                  StudyMetric(
                    '累计',
                    '${state.attemptCount}',
                    detail: '条记录，包含学习曝光',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 7, label: Text('近 7 天')),
                  ButtonSegment(value: 30, label: Text('近 30 天')),
                ],
                selected: {days},
                showSelectedIcon: false,
                onSelectionChanged: (v) => setState(() => days = v.single),
              ),
              const SizedBox(height: 20),
              _analytics(analytics, (a) => Column(children: _activity(a))),
              const SizedBox(height: 14),
              const Text(
                '按上海时间归日。图表统计实际练习尝试，不含仅显示答案的曝光。',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
            if (tab == 2) ...[
              const StudySection('回忆证据'),
              Row(
                children: [
                  StudyMetric(
                    '独立成功',
                    '${state.independentSuccessCount}',
                    detail: '次无提示回忆',
                  ),
                  StudyMetric(
                    '已选词',
                    '${state.progress.values.where((p) => p.selected).length}',
                    detail: '跨词书去重',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _analytics(analytics, _skills),
              const StudySection('选词状态'),
              ...WordDisposition.values.map(
                (kind) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(switch (kind) {
                    WordDisposition.active => '学习中',
                    WordDisposition.familiar => '手动标记熟知',
                    WordDisposition.paused => '暂停学习',
                  }),
                  trailing: Text(
                    '${state.progress.values.where((p) => p.selected && p.disposition == kind).length} 词',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '一次答对不等于掌握。手动熟知与独立回忆证据分别保存；发音未评测时不生成分数。',
                style: TextStyle(color: Colors.white54, height: 1.6),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _analytics(
    AsyncValue<StudyAnalytics> value,
    Widget Function(StudyAnalytics) render,
  ) => value.when(
    data: render,
    loading: () => const Padding(
      padding: EdgeInsets.all(24),
      child: Center(child: CircularProgressIndicator()),
    ),
    error: (_, _) => TextButton(
      onPressed: () => ref.invalidate(studyAnalyticsProvider),
      child: const Text('统计读取失败，点击重试'),
    ),
  );

  List<MemoryStatistics> _memories(StudyAnalytics a) =>
      a.memories.where((m) => skill == null || m.skill == skill).toList();

  Widget _forecast(StudyAnalytics a) {
    final memories = _memories(a);
    if (memories.isEmpty) {
      return const _EmptyStatistics(
        '还没有记忆预测',
        '先完成一次真实回忆练习。只有拥有 FSRS 记忆状态的技能卡片才会出现在这里。',
      );
    }
    final forecast = List.generate(
      StudyAnalytics.forecastDays.length,
      (index) =>
          memories.fold<double>(0, (sum, m) => sum + m.recallForecast[index]) /
          memories.length,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StudySection('如果暂时不复习'),
        Text(
          '${(forecast.first * 100).round()}%',
          style: const TextStyle(
            fontSize: 56,
            color: studyTeal,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          '当前平均回忆概率 · ${memories.length} 张技能卡',
          style: const TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 24),
        Semantics(
          label:
              'FSRS 模型预测：${List.generate(forecast.length, (i) => '${StudyAnalytics.forecastDays[i]} 天后 ${(forecast[i] * 100).round()}%').join('，')}',
          child: ExcludeSemantics(
            child: SizedBox(
              height: 240,
              child: CustomPaint(
                painter: _ForecastPainter(forecast),
                size: Size.infinite,
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        const Row(
          children: [
            Icon(Icons.circle, size: 8, color: studyTeal),
            SizedBox(width: 8),
            Expanded(
              child: Text('FSRS-6 模型预测', style: TextStyle(color: studyTeal)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          '曲线由实际技能卡片计算，假设期间没有新增复习。它是模型估计，不是已测正确率；当前使用默认参数，后续随练习证据更新。',
          style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 10),
        Text(
          '更新于 ${chinaTime(a.capturedAt)}',
          style: const TextStyle(color: Colors.white38, fontSize: 11),
        ),
      ],
    );
  }

  Widget _skills(StudyAnalytics a) {
    final selectedSkills = StudySkill.values.where(
      (s) => skill == null || skill == s,
    );
    final memories = _memories(a);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StudySection('分技能练习'),
        ...selectedSkills.map((s) {
          final stats = a.bySkill[s];
          if (stats == null || stats.attempts == 0) {
            return ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(skillLabel(s)),
              subtitle: Text(
                s == StudySkill.pronunciation ? '尚未接入评分，暂无发音证据' : '暂无练习证据',
              ),
              trailing: const Text(
                '—',
                style: TextStyle(color: Colors.white38),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(skillLabel(s))),
                    Text(
                      '${stats.attempts} 次',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: stats.independentSuccesses / stats.attempts,
                  minHeight: 5,
                  color: studyTeal,
                  backgroundColor: Colors.white10,
                ),
                const SizedBox(height: 8),
                Text(
                  '独立成功 ${stats.independentSuccesses} · 提示后 ${stats.hintedAttempts} · 忘记 ${stats.forgottenAttempts}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          );
        }),
        const Text(
          '条形表示独立成功占全部尝试的比例。提示与忘记分别统计，可能重叠。',
          style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.6),
        ),
        const StudySection('记忆稳定度'),
        if (memories.isEmpty)
          const _EmptyStatistics(
            '暂无稳定度记录',
            '稳定度只来自实际 FSRS 卡片。一张词义卡与一张拼写卡分别统计。',
          ),
        if (memories.isNotEmpty) ...[
          Text(
            '${memories.length} 张技能卡',
            style: const TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 10),
          for (final threshold in [10, 30, 60, 90])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('稳定度 ≥ $threshold 天')),
                      Text(
                        '${memories.where((m) => m.stabilityDays >= threshold).length} 张',
                        style: const TextStyle(color: studyTeal),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value:
                        memories
                            .where((m) => m.stabilityDays >= threshold)
                            .length /
                        memories.length,
                    minHeight: 5,
                    color: studyTeal,
                    backgroundColor: Colors.white10,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 10),
          const Text(
            '稳定度是模型估计的记忆持续时间。以上为累积阈值，彼此包含；不等于这些词已完全掌握。',
            style: TextStyle(color: Colors.white38, fontSize: 12, height: 1.6),
          ),
        ],
      ],
    );
  }

  List<Widget> _activity(StudyAnalytics analytics) {
    final now = analytics.capturedAt.toUtc().add(const Duration(hours: 8));
    final today = DateTime.utc(now.year, now.month, now.day);
    final entries = List.generate(days, (i) {
      final date = today.subtract(Duration(days: days - 1 - i));
      return (
        date: date,
        count:
            analytics.dailyAttempts[date.toIso8601String().substring(0, 10)] ??
            0,
      );
    });
    final maxValue = entries.fold<int>(1, (a, b) => b.count > a ? b.count : a);
    return [
      if (entries.every((e) => e.count == 0))
        const _EmptyStatistics('这段时间还没有练习', '完成回忆、拼写或听辨后，真实尝试会按日期显示。'),
      ...entries.map(
        (e) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              SizedBox(
                width: 46,
                child: Text(
                  '${e.date.month}/${e.date.day}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: e.count / maxValue,
                    minHeight: 12,
                    backgroundColor: Colors.white10,
                    color: studyTeal,
                  ),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text('${e.count}', textAlign: TextAlign.right),
              ),
            ],
          ),
        ),
      ),
    ];
  }
}

class _EmptyStatistics extends StatelessWidget {
  const _EmptyStatistics(this.title, this.description);
  final String title, description;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.insights_outlined, size: 36, color: Colors.white38),
        const SizedBox(height: 16),
        Text(title, style: const TextStyle(fontSize: 19)),
        const SizedBox(height: 10),
        Text(
          description,
          style: const TextStyle(color: Colors.white54, height: 1.6),
        ),
      ],
    ),
  );
}

class _ForecastPainter extends CustomPainter {
  const _ForecastPainter(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    const left = 38.0, top = 12.0, bottom = 30.0;
    final width = size.width - left - 8;
    final height = size.height - top - bottom;
    final grid = Paint()
      ..color = Colors.white10
      ..strokeWidth = 1;
    for (final value in [0, 25, 50, 75, 100]) {
      final y = top + height * (1 - value / 100);
      canvas.drawLine(Offset(left, y), Offset(left + width, y), grid);
      _label(canvas, '$value%', Offset(0, y - 6));
    }
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x =
          left +
          width *
              StudyAnalytics.forecastDays[i] /
              StudyAnalytics.forecastDays.last;
      final y = top + height * (1 - values[i].clamp(0, 1));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      if ([0, 7, 14, 30].contains(StudyAnalytics.forecastDays[i])) {
        _label(
          canvas,
          i == 0 ? '今天' : '${StudyAnalytics.forecastDays[i]}天',
          Offset(x - 10, top + height + 12),
        );
      }
      canvas.drawCircle(Offset(x, y), 3.5, Paint()..color = studyTeal);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = studyTeal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  void _label(Canvas canvas, String text, Offset at) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white54, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _ForecastPainter oldDelegate) =>
      oldDelegate.values != values;
}
