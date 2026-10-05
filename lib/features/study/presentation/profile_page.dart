import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../domain/study_models.dart';
import 'plan_page.dart';
import 'study_widgets.dart';

class StudyProfilePage extends ConsumerStatefulWidget {
  const StudyProfilePage({super.key});
  @override
  ConsumerState<StudyProfilePage> createState() => _ProfileState();
}

class _ProfileState extends ConsumerState<StudyProfilePage> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    final value = ref.watch(studyControllerProvider);
    return SafeArea(
      child: value.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: TextButton(
            onPressed: () => ref.invalidate(studyControllerProvider),
            child: const Text('设置读取失败，点击重试'),
          ),
        ),
        data: (state) => ListView(
          padding: const EdgeInsets.all(22),
          children: [
            const Text(
              '我的学习',
              style: TextStyle(fontSize: 30, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            const Text('拾语 / 自己的节奏', style: TextStyle(color: Colors.white54)),
            const StudySection('学习偏好'),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_note_outlined),
              title: const Text('每日学习计划'),
              subtitle: Text(
                '${state.preferences.dailyLimit} 词 / 新学最多 ${state.preferences.newLimit} 词 / ${state.preferences.budgetMinutes} 分钟',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => studyOpen(context, const StudyPlanPage()),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('静音学习'),
              subtitle: const Text('关闭自动发音，保留文字学习'),
              value: state.preferences.quiet,
              onChanged: busy ? null : (v) => _preference(state, {'quiet': v}),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('默认记忆方向'),
              subtitle: Text(switch (state.preferences.direction) {
                'cn-en' => '中文猜英文',
                'spell' => '拼写',
                'listen' => '听辨',
                _ => '英文猜中文',
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy ? null : () => _direction(state),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('学习目标'),
              subtitle: Text(state.preferences.goal),
              trailing: const Icon(Icons.edit_outlined),
              onTap: busy ? null : () => _goal(state),
            ),
            const StudySection('语音与发音'),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.mic_none),
              title: Text('MiniMax 云端语音识别'),
              subtitle: Text('需要网络，支持中英识别。按住说话或进入实时通话；识别文本不是发音评分。'),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.hearing_outlined),
              title: Text('腾讯 SOE · 关闭'),
              subtitle: Text('尚未接入评测密钥。基础对话和学习可继续，不显示模拟评分。'),
              trailing: Icon(Icons.lock_outline, color: Colors.white38),
            ),
            const StudySection('学习数据'),
            const Text(
              '选词、练习、复习点、计划和考试存储在英语学习专属数据库。备份不包含服务密钥。',
              style: TextStyle(color: Colors.white54, height: 1.6),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: busy ? null : _export,
              icon: const Icon(Icons.copy_all_outlined),
              label: const Text('导出并复制学习备份'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: busy ? null : _restore,
              icon: const Icon(Icons.restore_outlined),
              label: const Text('从备份恢复'),
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.all(12),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 24),
            const Text(
              'FSRS-6 · dart-fsrs 2.0.1\n时区：上海 UTC+8\n预设词库：ECDICT / MIT，保留来源与许可。',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 12,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _preference(
    StudySnapshot state,
    Map<String, dynamic> change,
  ) async {
    setState(() => busy = true);
    await studyCommit(
      context,
      ref,
      (r) => r.updatePreferences(
        studyCommandId(),
        change,
        expectedRevision: state.preferences.revision,
      ),
    );
    if (mounted) setState(() => busy = false);
  }

  Future<void> _direction(StudySnapshot state) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('默认记忆方向'),
        children: [
          for (final e in const {
            'en-cn': '英文猜中文',
            'cn-en': '中文猜英文',
            'spell': '拼写',
            'listen': '听辨',
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(c, e.key),
              child: Text(e.value),
            ),
        ],
      ),
    );
    if (choice != null && mounted) {
      await _preference(state, {'direction': choice});
    }
  }

  Future<void> _goal(StudySnapshot state) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (_) => StudyTextDialog(
        title: '学习目标',
        hint: '例如：能用英语介绍自己的工作',
        confirm: '保存',
        initial: state.preferences.goal,
        maxLines: 3,
        maxLength: 500,
      ),
    );
    if (choice != null && mounted) await _preference(state, {'goal': choice});
  }

  Future<void> _export() async {
    setState(() => busy = true);
    try {
      final data = await (await ref.read(
        studyRepositoryProvider.future,
      )).exportBackup();
      await Clipboard.setData(
        ClipboardData(text: const JsonEncoder.withIndent('  ').convert(data)),
      );
      if (mounted) studyMessage(context, '学习备份已复制，可粘贴到文件中保存。');
    } catch (error) {
      if (mounted) {
        studyMessage(
          context,
          error is StudyFailure ? error.message : '导出失败，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restore() async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const StudyTextDialog(
        title: '粘贴学习备份',
        hint: '粘贴导出的 JSON 备份',
        confirm: '检查备份',
        maxLines: 7,
      ),
    );
    if (text == null || !mounted) return;
    Map<String, dynamic> data;
    try {
      if (utf8.encode(text).length > 20 * 1024 * 1024) {
        throw const FormatException('备份超过 20 MB');
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic> ||
          decoded['schema'] != 1 ||
          decoded['namespace'] != 'english' ||
          decoded['tables'] is! Map) {
        throw const FormatException('不是有效英语学习备份');
      }
      data = decoded;
    } catch (_) {
      studyMessage(context, '备份格式无效，请粘贴完整英语学习备份。');
      return;
    }
    final tables = data['tables'] as Map;
    int count(String table) =>
        tables[table] is List ? (tables[table] as List).length : 0;
    final createdAt = DateTime.tryParse('${data['createdAt']}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('确认恢复学习备份'),
        content: Text(
          '备份时间：${createdAt == null ? '未提供' : chinaTime(createdAt)}\n词状态 ${count('word_state')} 条 · 练习 ${count('attempts')} 条\n复习点 ${count('review_points')} 条 · 考试 ${count('exams')} 次\n\n恢复会替换本应用当前英语学习记录。建议先导出当前数据。以上只是结构预览；备份会通过完整校验后，在事务中恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await (await ref.read(
        studyRepositoryProvider.future,
      )).restoreBackup(data);
      await ref.read(studyControllerProvider.notifier).refresh();
      if (mounted) studyMessage(context, '学习备份已恢复。');
    } catch (error) {
      if (mounted) {
        studyMessage(
          context,
          error is StudyFailure ? error.message : '恢复失败，当前记录未报告为已恢复。',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
