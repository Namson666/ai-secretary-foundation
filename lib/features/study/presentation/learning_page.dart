import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../application/study_providers.dart';
import '../application/study_runtime_provider.dart';
import '../domain/study_models.dart';
import '../domain/study_service.dart';
import 'study_widgets.dart';

class StudyLearningPage extends ConsumerStatefulWidget {
  const StudyLearningPage({super.key, required this.tasks}) : resume = false;
  const StudyLearningPage.resume({super.key}) : tasks = const [], resume = true;
  final List<StudyTask> tasks;
  final bool resume;
  @override
  ConsumerState<StudyLearningPage> createState() => _LearningState();
}

class _LearningState extends ConsumerState<StudyLearningPage> {
  List<StudyTask> tasks = [];
  int index = 0;
  AttemptEvidence? frozenEvidence;
  String? startupError;
  bool ending = false;
  bool ready = false,
      revealed = false,
      hinted = false,
      claimed = false,
      audioPlayed = false,
      reading = false,
      busy = false,
      submitted = false;
  String attemptId = studyCommandId(), answer = '', feedback = '';
  final input = TextEditingController();
  int audioEpoch = 0;
  Future<void> checkpointWrites = Future.value();
  StudyTask get task => tasks[index];
  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_initialize);
  }

  Future<void> _initialize() async {
    try {
      final repository = await ref.read(studyRepositoryProvider.future);
      if (!mounted) return;
      final snapshot = await repository.load();
      if (!mounted) return;
      final catalog = await ref.read(studyCatalogProvider.future);
      if (!mounted) return;
      if (widget.resume) {
        final saved = snapshot.session;
        if (saved != null) {
          try {
            tasks = (saved['tasks'] as List).map((v) {
              final t = Map<String, dynamic>.from(v as Map);
              return StudyTask(
                t['wordId'] as String,
                StudySkill.values.byName(t['skill'] as String),
                reviewId: t['reviewId'] as String?,
              );
            }).toList();
            index = saved['index'] as int;
            revealed = saved['revealed'] == true;
            hinted = saved['hinted'] == true;
            claimed = saved['claimed'] == true;
            reading = saved['reading'] == true;
            submitted = saved['submitted'] == true;
            answer = saved['answer'] as String? ?? '';
            feedback = saved['feedback'] as String? ?? '';
            attemptId = saved['attemptId'] as String? ?? studyCommandId();
            if (saved['frozenEvidence'] is Map) {
              frozenEvidence = AttemptEvidence.fromJson(
                Map<String, dynamic>.from(saved['frozenEvidence'] as Map),
              );
            }
          } catch (_) {
            tasks = [];
          }
        }
      } else {
        tasks = List.of(widget.tasks);
      }
      final originalCurrent = index >= 0 && index < tasks.length
          ? tasks[index]
          : null;
      tasks = tasks
          .where(
            (t) =>
                catalog.words.containsKey(t.wordId) &&
                snapshot.progress[t.wordId]?.selected == true &&
                snapshot.progress[t.wordId]?.disposition ==
                    WordDisposition.active,
          )
          .toList();
      final restoredIndex = tasks.indexWhere(
        (t) =>
            t.wordId == originalCurrent?.wordId &&
            t.skill == originalCurrent?.skill &&
            t.reviewId == originalCurrent?.reviewId,
      );
      if (restoredIndex >= 0) {
        index = restoredIndex;
      } else {
        index = 0;
        revealed = hinted = claimed = reading = submitted = false;
        answer = feedback = '';
        attemptId = studyCommandId();
        frozenEvidence = null;
      }
      if (tasks.isEmpty || index < 0 || index >= tasks.length) {
        if (mounted) {
          studyMessage(context, '本轮暂无有效学习任务，请从今日重新选择。');
          Navigator.pop(context);
        }
        return;
      }
      final receipt = await repository.receipt(attemptId);
      if (!mounted) return;
      if (receipt?.values['attempt_id'] == attemptId) {
        submitted = true;
        feedback = receipt!.message;
      }
      input.text = answer;
      ref.read(studyFocusProvider.notifier).set(task.wordId);
      if (mounted) setState(() => ready = true);
      await _save();
    } catch (error) {
      if (mounted) setState(() => startupError = '学习进度读取失败，请重试。');
    }
  }

  Future<void> _save() {
    if (!ready || tasks.isEmpty || ending) return Future.value();
    final payload = <String, dynamic>{
      'tasks': tasks
          .map(
            (t) => {
              'wordId': t.wordId,
              'skill': t.skill.name,
              'reviewId': t.reviewId,
            },
          )
          .toList(),
      'index': index,
      'revealed': revealed,
      'hinted': hinted,
      'claimed': claimed,
      'reading': reading,
      'submitted': submitted,
      'answer': answer,
      'feedback': feedback,
      'attemptId': attemptId,
      if (frozenEvidence != null) 'frozenEvidence': frozenEvidence!.toJson(),
    };
    final repositoryFuture = ref.read(studyRepositoryProvider.future);
    checkpointWrites = checkpointWrites.catchError((Object _) {}).then((
      _,
    ) async {
      await (await repositoryFuture).saveSession(payload);
    });
    return checkpointWrites;
  }

  void _change(VoidCallback change) {
    if (ending) return;
    setState(change);
    unawaited(
      _save().catchError((Object error) {
        if (!mounted) return;
        studyMessage(context, '学习进度保存失败，请重试。');
      }),
    );
  }

  Future<void> _play(String text, {bool target = true}) async {
    final prefs = ref.read(studyControllerProvider).asData?.value.preferences;
    if (prefs?.quiet == true) {
      studyMessage(context, '静音模式已开启；请关闭后播放，或选择阅读补练。');
      return;
    }
    final epoch = ++audioEpoch;
    final captured = task.wordId;
    final skill = task.skill;
    if (target && !revealed && skill == StudySkill.production) {
      _change(() => hinted = true);
    }
    final played = await ref.read(studyRuntimeProvider).playReference(text);
    if (!mounted ||
        epoch != audioEpoch ||
        task.wordId != captured ||
        task.skill != skill) {
      return;
    }
    if (played && skill == StudySkill.listening) {
      _change(() => audioPlayed = true);
    }
    if (!played) studyMessage(context, '音频未完整播放，未记录听辨完成。可以重试。');
  }

  Future<void> _record(
    RecallGrade grade, {
    bool? correct,
    String source = 'user_self_report',
  }) async {
    if (busy || submitted) return;
    setState(() => busy = true);
    final evidence =
        frozenEvidence ??
        AttemptEvidence(
          attemptId: attemptId,
          wordId: task.wordId,
          skill: task.skill,
          grade: grade,
          independent:
              source != 'practice_completed' &&
              source != 'reading_supplement' &&
              !hinted &&
              (claimed || source.startsWith('objective_')),
          hinted: hinted,
          source: source,
          answer: answer,
          correct: correct,
          reviewPointId: task.reviewId,
        );
    frozenEvidence = evidence;
    try {
      await _save();
    } catch (error) {
      if (mounted) {
        setState(() => busy = false);
        studyMessage(context, '首次作答保存失败，请重试原答案。');
      }
      return;
    }
    if (!mounted) return;
    final result = await studyCommit(
      context,
      ref,
      (r) => r.recordAttempt(attemptId, evidence),
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (result != null) {
      _change(() {
        submitted = true;
        feedback = evidence.grade == RecallGrade.again
            ? '这次没想起，继续安排复习。'
            : '本次练习已保存。单次成功不等于长期掌握。';
      });
    }
  }

  Future<void> _objective() async {
    if (frozenEvidence != null) {
      await _record(frozenEvidence!.grade);
      return;
    }
    if (task.skill == StudySkill.listening && !audioPlayed && !reading) {
      studyMessage(context, '先完整播放音频；听不到可以转为阅读补练。');
      return;
    }
    final word = (await ref.read(
      studyCatalogProvider.future,
    )).words[task.wordId]!;
    answer = input.text;
    final correct = answer.trim().toLowerCase() == word.word.toLowerCase();
    _change(() {
      revealed = true;
      claimed = true;
      feedback = correct ? '本次答对' : '这次未答对，正确单词是 ${word.word}';
    });
    await _record(
      correct ? RecallGrade.good : RecallGrade.again,
      correct: correct,
      source: reading
          ? 'reading_supplement'
          : task.skill == StudySkill.spelling
          ? 'objective_text'
          : 'objective_listening',
    );
  }

  Future<void> _next() async {
    if (!submitted || ending || busy) return;
    ++audioEpoch;
    if (index + 1 >= tasks.length) {
      final saved = _save();
      setState(() => ending = true);
      try {
        await saved;
        if (!mounted) return;
        final receipt = await studyCommit(
          context,
          ref,
          (r) => r.endSession(studyCommandId()),
        );
        if (receipt != null && mounted) Navigator.pop(context);
      } catch (error) {
        if (mounted) studyMessage(context, '结束前保存失败，请重试。本轮进度仍保留。');
      } finally {
        if (mounted) setState(() => ending = false);
      }
      return;
    }
    _change(() {
      index++;
      revealed = hinted = claimed = audioPlayed = reading = submitted = false;
      answer = feedback = '';
      input.clear();
      attemptId = studyCommandId();
      frozenEvidence = null;
    });
    ref.read(studyFocusProvider.notifier).set(task.wordId);
  }

  @override
  void dispose() {
    audioEpoch++;
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) {
      return Scaffold(
        body: Center(
          child: startupError == null
              ? const CircularProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(startupError!),
                    TextButton(
                      onPressed: () {
                        setState(() => startupError = null);
                        unawaited(_initialize());
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
        ),
      );
    }
    final word = ref
        .watch(studyCatalogProvider)
        .asData!
        .value
        .words[task.wordId]!;
    final reverse = task.skill == StudySkill.production;
    final recall = task.skill == StudySkill.meaning || reverse;
    final visibleMeaning = reverse || revealed;
    final visibleEnglish = !reverse || revealed;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          '${index + 1} / ${tasks.length} · ${skillLabel(task.skill)}',
        ),
        actions: [
          IconButton(
            tooltip: '收录明天发音复习',
            onPressed: () => studyCommit(
              context,
              ref,
              (r) => r.addReview(
                studyCommandId(),
                task.wordId,
                StudySkill.pronunciation,
                source: 'card_action',
                requestedDue: StudyService.chinaDay(
                  DateTime.now(),
                ).add(const Duration(days: 1, hours: 19, minutes: 30)),
              ),
            ),
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (recall)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('英 → 中'),
                    selected: !reverse,
                    onSelected: submitted || frozenEvidence != null
                        ? null
                        : (_) => _direction(StudySkill.meaning),
                  ),
                  const SizedBox(width: 12),
                  ChoiceChip(
                    label: const Text('中 → 英'),
                    selected: reverse,
                    onSelected: submitted || frozenEvidence != null
                        ? null
                        : (_) => _direction(StudySkill.production),
                  ),
                ],
              ),
            const SizedBox(height: 35),
            if (task.skill == StudySkill.spelling)
              const Text('看中文，写出英文', style: TextStyle(color: Colors.white54)),
            if (task.skill == StudySkill.listening) ...[
              const Text('听完整个单词，写出你听到的英文'),
              const SizedBox(height: 30),
              FilledButton.icon(
                onPressed: () => _play(word.word),
                icon: const Icon(Icons.volume_up),
                label: const Text('播放听辨音频'),
              ),
            ],
            if (task.skill != StudySkill.listening)
              Text(
                task.skill == StudySkill.spelling
                    ? word.meaning
                    : visibleEnglish
                    ? word.word
                    : word.meaning,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize:
                      reverse && !revealed || task.skill == StudySkill.spelling
                      ? 25
                      : 42,
                  fontWeight: FontWeight.w500,
                ),
              ),
            if (task.skill != StudySkill.spelling &&
                task.skill != StudySkill.listening)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (visibleEnglish)
                    Text(
                      word.ipa.isEmpty ? '音标暂无' : word.ipa,
                      style: const TextStyle(color: Colors.white54),
                    ),
                  IconButton(
                    tooltip: '播放单词发音',
                    onPressed: () => _play(word.word),
                    icon: const Icon(
                      Icons.volume_up_outlined,
                      color: studyTeal,
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 30),
            if (recall && !revealed) ...[
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _change(() {
                  revealed = true;
                  hinted = true;
                }),
                child: Container(
                  height: 160,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xff1b1f20),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    '点击显示答案',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              ),
              const SizedBox(height: 25),
              FilledButton(
                onPressed: () => _change(() {
                  claimed = true;
                  revealed = true;
                }),
                child: const Text('我已独立想起，核对答案'),
              ),
              TextButton(
                onPressed: () => _change(() {
                  revealed = true;
                  hinted = true;
                }),
                child: const Text('没想起，看看答案'),
              ),
              TextButton(
                onPressed: word.hint.isEmpty
                    ? null
                    : () => _change(() => hinted = true),
                child: Text(
                  hinted && word.hint.isNotEmpty
                      ? word.hint
                      : word.hint.isEmpty
                      ? '暂无额外提示'
                      : '给一点提示',
                ),
              ),
            ],
            if ((task.skill == StudySkill.spelling ||
                    task.skill == StudySkill.listening) &&
                !submitted) ...[
              if (task.skill == StudySkill.spelling) const SizedBox(height: 10),
              TextField(
                controller: input,
                readOnly: frozenEvidence != null,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '你的英文答案'),
                onChanged: (v) {
                  answer = v;
                  unawaited(
                    _save().catchError((Object error) {
                      if (context.mounted) {
                        studyMessage(context, '学习进度保存失败，请重试。');
                      }
                    }),
                  );
                },
                onSubmitted: (_) => _objective(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: busy ? null : _objective,
                child: const Text('提交答案'),
              ),
              if (task.skill == StudySkill.listening)
                TextButton(
                  onPressed: () => _change(() {
                    reading = true;
                    hinted = true;
                  }),
                  child: const Text('听不到？转为阅读补练'),
                ),
              if (reading)
                Text(
                  word.word,
                  style: const TextStyle(fontSize: 24, color: studyTeal),
                ),
            ],
            if (revealed) ...[
              if (visibleMeaning || !recall)
                Text(
                  word.meaning,
                  style: const TextStyle(fontSize: 21, height: 1.6),
                ),
              if (reverse ||
                  task.skill == StudySkill.spelling ||
                  task.skill == StudySkill.listening)
                Text(
                  word.word,
                  style: const TextStyle(fontSize: 30, color: studyTeal),
                ),
              const SizedBox(height: 20),
              if (word.example.isNotEmpty) ...[
                Text(
                  word.example,
                  style: const TextStyle(fontSize: 18, height: 1.5),
                ),
                Text(
                  word.translation,
                  style: const TextStyle(color: Colors.white54),
                ),
                Text(
                  '例句：${word.exampleSource}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                TextButton.icon(
                  onPressed: () => _play(word.example, target: false),
                  icon: const Icon(Icons.volume_up_outlined),
                  label: const Text('播放例句'),
                ),
              ] else
                const Text(
                  '暂无例句，可添加个人笔记。',
                  style: TextStyle(color: Colors.white54),
                ),
              Text(
                '释义：${word.source}',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
              if (recall && !submitted) ...[
                const SizedBox(height: 24),
                Text(
                  hinted ? '本轮使用提示，只记录补练。' : '请核对刚才独立想到的答案。',
                  style: const TextStyle(color: Colors.white54),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => _record(RecallGrade.again, correct: false),
                      child: const Text('忘记 / 没想起'),
                    ),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => _record(RecallGrade.again, correct: true),
                      child: const Text('借提示想起'),
                    ),
                    FilledButton(
                      onPressed: busy || hinted || !claimed
                          ? null
                          : () => _record(RecallGrade.hard, correct: true),
                      child: const Text('独立但吃力'),
                    ),
                    FilledButton(
                      onPressed: busy || hinted || !claimed
                          ? null
                          : () => _record(RecallGrade.good, correct: true),
                      child: const Text('独立想起'),
                    ),
                  ],
                ),
              ],
            ],
            if (task.skill == StudySkill.pronunciation) ...[
              const Text('听示范并跟读，不自动发音评分。'),
              FilledButton.icon(
                onPressed: () => _play(word.word),
                icon: const Icon(Icons.volume_up),
                label: const Text('播放示范'),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: busy || submitted
                    ? null
                    : () => _record(
                        RecallGrade.again,
                        source: 'practice_completed',
                      ),
                child: const Text('我完成了跟读自练'),
              ),
              const Text(
                'SOE 未启用 · 本次不会产生发音分数',
                style: TextStyle(color: Colors.white54),
              ),
            ],
            if (feedback.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(feedback, style: const TextStyle(color: studyTeal)),
              ),
            if (frozenEvidence != null && !submitted)
              FilledButton(
                onPressed: busy ? null : () => _record(frozenEvidence!.grade),
                child: const Text('重试保存首次作答'),
              ),
            if (submitted)
              FilledButton(
                onPressed: _next,
                child: Text(index + 1 == tasks.length ? '完成本轮' : '下一个'),
              ),
            const SizedBox(height: 25),
          ],
        ),
      ),
    );
  }

  void _direction(StudySkill skill) {
    if (skill == task.skill) return;
    ++audioEpoch;
    _change(() {
      tasks[index] = StudyTask(task.wordId, skill);
      revealed = hinted = claimed = audioPlayed = reading = false;
      attemptId = studyCommandId();
      frozenEvidence = null;
    });
  }
}
