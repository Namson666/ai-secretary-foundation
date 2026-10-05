import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../domain/study_repository.dart';
import '../domain/study_models.dart';
import 'study_widgets.dart';

class StudyExamPage extends ConsumerStatefulWidget {
  const StudyExamPage({super.key});
  @override
  ConsumerState<StudyExamPage> createState() => _ExamState();
}

class _ExamState extends ConsumerState<StudyExamPage> {
  final answers = <String, String>{};
  bool busy = false;
  String? initializedExam;
  Future<void> answerWrites = Future.value();
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(studyControllerProvider).asData?.value;
    final catalog = ref.watch(studyCatalogProvider).asData?.value;
    if (state == null || catalog == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final exam =
        state.exams.where((e) => e['status'] != 'published').firstOrNull ??
        state.exams.firstOrNull;
    final active = exam?['status'] == 'active';
    if (active && initializedExam != exam!['id']) {
      initializedExam = exam['id'] as String;
      answers.addAll((exam['answers'] as Map).cast<String, String>());
    }
    return PopScope(
      canPop: !active,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: !active,
          title: const Text('阶段考试'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(22),
          children: [
            if (exam == null || exam['status'] == 'published') ...[
              const Text(
                '测一测实际回忆',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              const Text(
                '从所选词中取5题中→英拼写。试卷开始后冻结题目和规则；交卷后单独评分、发布。发音不自动评分。',
                style: TextStyle(color: Colors.white54, height: 1.6),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: busy
                    ? null
                    : () async {
                        final chosen = state.progress.values
                            .where((p) => p.selected)
                            .take(5)
                            .map((p) => catalog.words[p.wordId]!)
                            .toList();
                        if (chosen.isEmpty) {
                          studyMessage(context, '先选词再开考。');
                          return;
                        }
                        answers.clear();
                        await _run(
                          (r) => r.startExam(studyCommandId(), {
                            'pronunciationScoring': 'disabled',
                            'rules': 'exact-match-v1',
                            'items': chosen
                                .map(
                                  (w) => {
                                    'id': w.id,
                                    'prompt': w.meaning,
                                    'answer': w.word,
                                    'explanation': w.meaning,
                                  },
                                )
                                .toList(),
                          }),
                        );
                      },
                child: const Text('确认范围并开始考试'),
              ),
            ],
            if (exam != null) ...[
              const SizedBox(height: 24),
              Text(switch (exam['status']) {
                'active' => '正在作答',
                'submitted' => '已交卷 · 待评分',
                'graded' => '评分完成 · 未发布',
                _ => '已发布成绩',
              }, style: const TextStyle(fontSize: 23, color: studyTeal)),
              if (active) ...[
                ...(exam['config']['items'] as List).map<Widget>((raw) {
                  final item = raw as Map;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item['prompt'] as String),
                        const SizedBox(height: 8),
                        TextFormField(
                          initialValue:
                              (exam['answers'] as Map)[item['id']] as String? ??
                              answers[item['id']] ??
                              '',
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(labelText: '英文答案'),
                          onChanged: (v) => _saveAnswer(
                            exam['id'] as String,
                            item['id'] as String,
                            v,
                          ),
                        ),
                      ],
                    ),
                  );
                }),
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => _run(
                          (r) => r.submitExam(
                            studyCommandId(),
                            exam['id'] as String,
                            answers,
                          ),
                        ),
                  child: const Text('确认交卷'),
                ),
              ],
              if (exam['status'] == 'submitted')
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => _run(
                          (r) => r.gradeExam(
                            studyCommandId(),
                            exam['id'] as String,
                          ),
                        ),
                  child: const Text('完成客观评分'),
                ),
              if (exam['status'] == 'graded')
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => _run(
                          (r) => r.publishExam(
                            studyCommandId(),
                            exam['id'] as String,
                          ),
                        ),
                  child: const Text('发布本场成绩'),
                ),
              if (exam['status'] == 'published') ...[
                Text(
                  '${exam['grade']['score']} / ${exam['grade']['total']}',
                  style: const TextStyle(fontSize: 50),
                ),
                const Text(
                  '范围：本场中→英拼写；不是综合英语水平。',
                  style: TextStyle(color: Colors.white54),
                ),
                ...(exam['grade']['results'] as List).map((raw) {
                  final result = raw as Map;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      result['correct'] == true
                          ? Icons.check_circle_outline
                          : Icons.highlight_off,
                      color: result['correct'] == true
                          ? studyTeal
                          : Colors.orange,
                    ),
                    title: Text('你的答案：${result['answer']}'),
                    subtitle: Text(
                      '正确答案：${result['reference']}\n${result['explanation']}',
                    ),
                  );
                }),
              ],
            ],
          ],
        ),
      ),
    );
  }

  void _saveAnswer(String examId, String itemId, String value) {
    answers[itemId] = value;
    final saved = Map<String, String>.of(answers);
    final repositoryFuture = ref.read(studyRepositoryProvider.future);
    answerWrites = answerWrites.catchError((Object _) {}).then((_) async {
      try {
        await (await repositoryFuture).saveExamDraft(examId, saved);
      } catch (error) {
        if (mounted) studyMessage(context, '草稿保存失败，请重试；尚未交卷。');
        rethrow;
      }
    });
    // The next edit or submission recovers the chain; keep the current failure observable.
    unawaited(answerWrites.catchError((Object _) {}));
  }

  Future<void> _run(
    Future<CommitReceipt> Function(StudyRepository) action,
  ) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await answerWrites.catchError((Object _) {});
      final snapshot = ref.read(studyControllerProvider).asData?.value;
      final active = snapshot?.exams
          .where((e) => e['status'] == 'active')
          .firstOrNull;
      if (active != null) {
        await (await ref.read(
          studyRepositoryProvider.future,
        )).saveExamDraft(active['id'] as String, Map.of(answers));
      }
      if (!mounted) return;
      await studyCommit(context, ref, action);
    } catch (error) {
      if (mounted) studyMessage(context, '保存或提交失败，可以重试。试卷尚未报告为已提交。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
