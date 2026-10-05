import '../domain/study_models.dart';
import '../domain/study_repository.dart';
import '../domain/study_service.dart';

class StudyToolContext {
  const StudyToolContext({
    required this.commandId,
    required this.userText,
    required this.isCurrent,
    this.focusId,
  });
  final String commandId, userText;
  final String? focusId;
  final bool Function() isCurrent;
}

class StudyTools {
  StudyTools(
    this.repository,
    this.catalog, {
    DateTime Function()? clock,
    this.audioPlayer,
  }) : clock = clock ?? DateTime.now;
  final StudyRepository repository;
  final StudyCatalog catalog;
  final DateTime Function() clock;
  final Future<bool> Function(String text, bool Function() isCurrent)?
  audioPlayer;
  String? _lastOperationId;
  String? _lastProposalId;
  static bool denied(String text) => RegExp(
    r"不要|不想|不需要|不必|不用|不再|别|勿|无需|don.t|do not|don't|never|should not",
    caseSensitive: false,
  ).hasMatch(text);
  static bool querying(String text) => RegExp(
    r'什么|怎么|如何|是否|为什么|能否|what is|how does|how to|tell me how|can i |why|show|查询|查看',
    caseSensitive: false,
  ).hasMatch(text);
  static final specifications = <Map<String, dynamic>>[
    for (final name in [
      'capabilities_list',
      'knowledge_search',
      'learner_get_state',
      'session_get_state',
      'plan_propose',
      'plan_activate',
      'session_control',
      'feedback_list',
      'review_point_add',
      'review_point_undo',
      'practice_start',
      'assessment_get_result',
      'audio_play',
      'exam_start',
    ])
      {
        'type': 'function',
        'function': {
          'name': 'study_$name',
          'description': _description(name),
          'parameters': {
            'type': 'object',
            'properties': {
              'word_id': {
                'type': 'string',
                'description': '用户明确指定的词头；“这个词”可留空，使用冻结焦点',
              },
              'skill': {
                'type': 'string',
                'enum': StudySkill.values.map((s) => s.name).toList(),
              },
              'operation_id': {'type': 'string'},
              'proposal_id': {'type': 'string'},
              'query': {'type': 'string'},
              'mode': {
                'type': 'string',
                'enum': ['manual', 'assisted', 'managed'],
              },
              'new_limit': {'type': 'integer'},
              'daily_limit': {'type': 'integer'},
              'budget_minutes': {'type': 'integer'},
              'action': {
                'type': 'string',
                'enum': ['start', 'pause', 'resume', 'end'],
              },
            },
            'additionalProperties': false,
          },
        },
      },
  ];
  static String _description(String name) => switch (name) {
    'review_point_add' => '用户明确要求加入复习时才调用；返回真实保存回执，不等于已安排。',
    'review_point_undo' => '撤销指定操作贡献，保留其他贡献和学习历史。',
    'knowledge_search' => '查公开词条，考试中不可查答案。',
    'plan_propose' => '读取真实状态和预算，提出可执行候选，不直接激活。',
    'plan_activate' => '只有用户明确授权且当前计划版本有效才激活预算内计划。',
    _ => '查询或控制真实学习服务 $name，不能自行编造结果。',
  };
  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, dynamic> args,
    StudyToolContext context,
  ) async {
    try {
      return await repository.withCommandLease(context.isCurrent, () async {
        if (!context.isCurrent()) {
          throw const StudyFailure('CANCELLED', '当前指令已取消。');
        }
        final state = await repository.load();
        final exam = state.exams
            .where((e) => e['status'] == 'active')
            .firstOrNull;
        if (exam != null &&
            !{
              'study_capabilities_list',
              'study_learner_get_state',
              'study_session_get_state',
              'study_assessment_get_result',
            }.contains(name)) {
          throw const StudyFailure('MODE_FORBIDDEN', '考试进行中，学习工具不能显示答案或执行练习。');
        }
        if (name == 'study_capabilities_list') {
          return {
            'status': 'ok',
            'namespace': 'english',
            'memoryModel': 'FSRS-6 / dart-fsrs 2.0.1',
            'speechEvaluation': {
              'enabled': false,
              'reason': 'provider_disabled',
            },
            'tools': specifications
                .map((s) => (s['function'] as Map)['name'])
                .toList(),
          };
        }
        if (name == 'study_learner_get_state') {
          return {
            'status': 'ok',
            'revision': state.preferences.revision,
            'savedAttempts': state.attemptCount,
            'independentSuccesses': state.independentSuccessCount,
            'selectedWords': state.progress.values
                .where((p) => p.selected)
                .length,
            'dueTasks': StudyService(
              repository,
              catalog,
              clock: clock,
            ).dailyQueue(state).where((t) => t.reviewId != null).length,
            'preferences': state.preferences.toJson(),
            'syncStatus': 'local_only',
          };
        }
        if (name == 'study_session_get_state') {
          return {
            'status': 'ok',
            'focusWordId': context.focusId,
            'session': exam == null ? state.session : null,
            'examActive': exam != null,
          };
        }
        if (name == 'study_knowledge_search') {
          final query =
              args['query'] as String? ?? args['word_id'] as String? ?? '';
          return {
            'status': 'ok',
            'entries': catalog.words.values
                .where(
                  (w) =>
                      w.word.contains(query.toLowerCase()) ||
                      w.meaning.contains(query),
                )
                .take(8)
                .map(
                  (w) => {
                    'id': w.id,
                    'word': w.word,
                    'meaning': w.meaning,
                    'ipa': w.ipa,
                    'source': w.source,
                    'example': w.example,
                    'exampleSource': w.exampleSource,
                  },
                )
                .toList(),
          };
        }
        if (name == 'study_plan_propose') {
          final changes = <String, dynamic>{
            if (args['new_limit'] != null) 'newLimit': args['new_limit'],
            if (args['daily_limit'] != null) 'dailyLimit': args['daily_limit'],
            if (args['budget_minutes'] != null)
              'budgetMinutes': args['budget_minutes'],
            if (args['mode'] != null) 'mode': args['mode'],
          };
          final proposal = await repository.proposePlan(
            context.commandId,
            changes,
          );
          _lastProposalId = proposal.values['proposal_id'] as String;
          return proposal.values;
        }
        if (name == 'study_plan_activate') {
          if (denied(context.userText) ||
              querying(context.userText) ||
              !RegExp(
                r'确认.*计划|启用.*计划|安排.*计划|按.*计划|开始.*托管|activate.*plan|confirm.*plan|apply.*plan',
                caseSensitive: false,
              ).hasMatch(context.userText)) {
            throw const StudyFailure('AUTHORIZATION_REQUIRED', '计划激活需要明确肯定指令。');
          }
          final proposal = args['proposal_id'] as String? ?? _lastProposalId;
          if (proposal == null) {
            throw const StudyFailure('INVALID_ARGUMENT', '没有可确认计划，请先制订草案。');
          }
          return (await repository.activatePlan(
            context.commandId,
            proposal,
          )).values;
        }
        if (name == 'study_review_point_add') {
          if (denied(context.userText) ||
              querying(context.userText) ||
              !RegExp(
                r'加入|收录|复习|练|记住|add|review|practice|remember',
                caseSensitive: false,
              ).hasMatch(context.userText) ||
              RegExp(
                r'不要|不想|别|取消|don.t|do not',
                caseSensitive: false,
              ).hasMatch(context.userText)) {
            throw const StudyFailure(
              'AUTHORIZATION_REQUIRED',
              '没有明确加入复习的用户指令。',
            );
          }
          final word = _target(args, context);
          final skill = StudySkill.values.byName(
            args['skill'] as String? ?? 'pronunciation',
          );
          final receipt = await StudyService(
            repository,
            catalog,
            clock: clock,
          ).addFrozenReview(context.commandId, word, skill: skill);
          _lastOperationId = receipt.operationId;
          return receipt.values;
        }
        if (name == 'study_review_point_undo') {
          if (denied(context.userText) ||
              querying(context.userText) ||
              !RegExp(
                r'撤销|取消刚才|undo',
                caseSensitive: false,
              ).hasMatch(context.userText)) {
            throw const StudyFailure('AUTHORIZATION_REQUIRED', '没有撤销指令。');
          }
          final operation = args['operation_id'] as String? ?? _lastOperationId;
          if (operation == null ||
              operation != _lastOperationId &&
                  !context.userText.contains(operation)) {
            throw const StudyFailure('INVALID_ARGUMENT', '无法定位本会话的可撤销贡献。');
          }
          final receipt = await repository.undo(context.commandId, operation);
          if (operation == _lastOperationId) _lastOperationId = null;
          return receipt.values;
        }
        if (name == 'study_feedback_list' ||
            name == 'study_assessment_get_result') {
          return {
            'status': 'ok',
            'recentUndoableOperationId': _lastOperationId,
            'pendingProposalId': _lastProposalId,
            'pronunciationAssessment': 'not_assessed',
            'reason': 'provider_disabled',
            'examResults': state.exams
                .where((e) => e['status'] == 'published')
                .map((e) => {'id': e['id'], 'grade': e['grade']})
                .toList(),
          };
        }
        if (name == 'study_session_control') {
          final action = args['action'] as String? ?? 'start';
          if (denied(context.userText) || querying(context.userText)) {
            throw const StudyFailure('AUTHORIZATION_REQUIRED', '需要明确的学习控制指令。');
          }
          if (action == 'end') {
            if (!RegExp(
              r'结束.*学习|停止.*学习|end.*study|stop.*learning',
              caseSensitive: false,
            ).hasMatch(context.userText)) {
              throw const StudyFailure('AUTHORIZATION_REQUIRED', '结束学习需要明确指令。');
            }
            return (await repository.endSession(context.commandId)).values;
          }
          final phrase = switch (action) {
            'pause' => r'暂停.*学习|pause.*study',
            'resume' => r'继续.*学习|恢复.*学习|resume.*study',
            _ => r'开始.*学习|start.*study',
          };
          if (!RegExp(
            phrase,
            caseSensitive: false,
          ).hasMatch(context.userText)) {
            throw const StudyFailure('AUTHORIZATION_REQUIRED', '没有相应学习控制授权。');
          }
          Map<String, dynamic>? session;
          if (action == 'start') {
            final tasks = StudyService(
              repository,
              catalog,
              clock: clock,
            ).dailyQueue(state);
            session = {
              'tasks': tasks
                  .map(
                    (t) => {
                      'wordId': t.wordId,
                      'skill': t.skill.name,
                      'reviewId': t.reviewId,
                    },
                  )
                  .toList(),
              'index': 0,
            };
          }
          return (await repository.controlSession(
            context.commandId,
            action,
            session: session,
          )).values;
        }
        if (name == 'study_practice_start') {
          if (denied(context.userText) ||
              querying(context.userText) ||
              !RegExp(
                r'练|学习|practice|learn',
                caseSensitive: false,
              ).hasMatch(context.userText)) {
            throw const StudyFailure('AUTHORIZATION_REQUIRED', '开始练习需要明确指令。');
          }
          final word = _target(args, context);
          final skill = StudySkill.values.byName(
            args['skill'] as String? ?? 'meaning',
          );
          return (await repository.controlSession(
            context.commandId,
            'start',
            session: {
              'tasks': [
                {'wordId': word, 'skill': skill.name},
              ],
              'index': 0,
            },
          )).values;
        }
        if (name == 'study_audio_play') {
          if (denied(context.userText) ||
              querying(context.userText) ||
              !RegExp(
                r'播放|读|发音|play|pronounce|read|say',
                caseSensitive: false,
              ).hasMatch(context.userText)) {
            throw const StudyFailure('AUTHORIZATION_REQUIRED', '播放需要明确指令。');
          }
          final word = _target(args, context);
          if (audioPlayer == null) {
            throw const StudyFailure('CAPABILITY_UNAVAILABLE', '当前音频服务不可用。');
          }
          final played = await audioPlayer!(
            catalog.words[word]!.word,
            context.isCurrent,
          );
          return {
            'status': played ? 'ok' : 'capability_unavailable',
            'audio_status': played ? 'played' : 'not_played',
            'message': played ? '参考读音已完整播放。' : '音频当前忙碌或不可用，未声称已播放。',
          };
        }
        if (name == 'study_exam_start') {
          if (denied(context.userText) ||
              querying(context.userText) ||
              !RegExp(
                r'开始.*考试|开始.*测验|start.*exam|start.*test',
                caseSensitive: false,
              ).hasMatch(context.userText)) {
            throw const StudyFailure('AUTHORIZATION_REQUIRED', '考试需要明确开考指令。');
          }
          final chosen = state.progress.values
              .where(
                (p) => p.selected && p.disposition != WordDisposition.paused,
              )
              .take(5)
              .map((p) => catalog.words[p.wordId]!)
              .toList();
          return (await repository.startExam(context.commandId, {
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
          })).values;
        }
        throw const StudyFailure('INVALID_ARGUMENT', '工具不存在。');
      });
    } catch (error) {
      return {
        'status': error is StudyFailure && error.code == 'CANCELLED'
            ? 'cancelled'
            : 'rejected',
        'code': error is StudyFailure ? error.code : 'STORAGE_FAILURE',
        'message': error is StudyFailure ? error.message : '操作未能提交，请查询回执后重试。',
        'commit_state': 'none',
      };
    }
  }

  String _target(Map<String, dynamic> args, StudyToolContext context) {
    const controls = {
      'add',
      'this',
      'word',
      'to',
      'review',
      'tomorrow',
      'practice',
      'pronunciation',
      'please',
      'my',
      'the',
      'plan',
      'save',
      'later',
      'and',
      'a',
      'for',
      'in',
      'on',
      'remember',
      'it',
      'english',
      'i',
      'want',
      'would',
      'like',
      'can',
      'could',
      'you',
      'me',
      'read',
      'say',
      'pronounce',
      'play',
      'an',
      'next',
      'that',
      'today',
      'now',
      'will',
    };
    final named = RegExp(r"[a-z]+(?:['-][a-z]+)*")
        .allMatches(context.userText.toLowerCase())
        .map((m) => m.group(0)!)
        .where((w) => !controls.contains(w) && catalog.words.containsKey(w))
        .toSet();
    final hasDeictic = RegExp(
      r'这个词|当前词|this word',
      caseSensitive: false,
    ).hasMatch(context.userText);
    final spans = <String>{};
    for (final pattern in [
      r'(?:把|将|单词)\s*[“"\u0027]?([a-z]+(?:[\u0027-][a-z]+)*)',
      r'(?:add|review|practice|pronounce|read|play|remember)\s+(?:the word\s+)?["\u0027]?([a-z]+(?:[\u0027-][a-z]+)*)',
      r'[“"\u0027]([a-z]+(?:[\u0027-][a-z]+)*)[”"\u0027]',
    ]) {
      for (final match in RegExp(
        pattern,
        caseSensitive: false,
      ).allMatches(context.userText)) {
        final word = match.group(1)!.toLowerCase();
        if (!{'this', 'that', 'it', 'word', 'the'}.contains(word)) {
          if (!catalog.words.containsKey(word)) {
            throw const StudyFailure(
              'NEEDS_CLARIFICATION',
              '显式单词不在内置词库，请确认拼写。',
            );
          }
          spans.add(word);
        }
      }
    }
    if (spans.length > 1 || !hasDeictic && spans.isEmpty && named.length > 1) {
      throw const StudyFailure('NEEDS_CLARIFICATION', '涉及多个单词，请明确一个目标。');
    }
    final explicit = args['word_id'] as String?;
    final target =
        spans.firstOrNull ?? (hasDeictic ? context.focusId : named.firstOrNull);
    if (target == null ||
        !catalog.words.containsKey(target) ||
        explicit != null && explicit != target) {
      throw const StudyFailure('NEEDS_CLARIFICATION', '无法唯一定位目标，请说出具体单词。');
    }
    return target;
  }
}
