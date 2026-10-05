import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ai_secretary/features/study/data/sqlite_study_repository.dart';
import 'package:ai_secretary/features/study/data/fsrs_scheduler.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study/domain/study_service.dart';
import 'package:ai_secretary/features/study/application/study_tools.dart';

void main() {
  sqfliteFfiInit();
  late StudyCatalog catalog;
  late SqliteStudyRepository repo;
  late Directory temp;
  var now = DateTime.utc(2026, 10, 5, 0);
  setUp(() async {
    now = DateTime.utc(2026, 10, 5, 0);
    catalog = StudyCatalog.fromJson(
      jsonDecode(await File('assets/study/vocabulary.json').readAsString())
          as Map<String, dynamic>,
    );
    temp = await Directory.systemTemp.createTemp('study-regression-');
    repo = await SqliteStudyRepository.open(
      catalog,
      Fsrs6Scheduler(fuzz: false),
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/study.sqlite',
      clock: () => now,
    );
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<void> attempt(
    String id, {
    String source = 'user_self_report',
    bool independent = true,
  }) async {
    await repo.recordAttempt(
      id,
      AttemptEvidence(
        attemptId: id,
        wordId: 'ship',
        skill: StudySkill.meaning,
        grade: independent ? RecallGrade.good : RecallGrade.again,
        independent: independent,
        hinted: false,
        source: source,
        answer: '',
        correct: independent,
      ),
    );
  }

  test(
    'manual contribution created first then FSRS remains after undo',
    () async {
      final add = await repo.addReview(
        'add',
        'ship',
        StudySkill.meaning,
        source: 'user_request',
      );
      final p = (await repo.load()).reviews.single;
      await repo.schedule(
        'schedule',
        p.id,
        now.add(const Duration(hours: 2)),
        expectedRevision: p.revision,
      );
      await attempt('a');
      await repo.undo('undo', add.operationId);
      final result = (await repo.load()).reviews.single;
      expect(result.status, 'planned');
      expect(result.dueAt, isNotNull);
      expect((await repo.database.query('memory_states')).length, 1);
    },
  );
  test(
    'Again replaces overdue automatic due with future FSRS learning step',
    () async {
      await attempt('a', independent: false);
      now = now.add(const Duration(minutes: 2));
      await attempt('b', independent: false);
      final point = (await repo.load()).reviews.single;
      expect(point.dueAt!.isAfter(now), true);
      expect(
        StudyService(
          repo,
          catalog,
          clock: () => now,
        ).dailyQueue(await repo.load()).where((t) => t.reviewId != null),
        isEmpty,
      );
    },
  );
  test(
    'pending receipt offers suggested due only while scheduled receipt matches stored due',
    () async {
      await repo.addReview(
        'add',
        'ship',
        StudySkill.meaning,
        source: 'user_request',
      );
      final receipt = await repo.recordAttempt(
        'attempt',
        const AttemptEvidence(
          attemptId: 'a',
          wordId: 'ship',
          skill: StudySkill.meaning,
          grade: RecallGrade.good,
          independent: true,
          hinted: false,
          source: 'user_self_report',
          answer: '',
        ),
      );
      expect(receipt.values['schedule_status'], 'pending');
      expect(receipt.values.containsKey('next_due_at'), false);
      expect(receipt.values['suggested_due_at'], isNotNull);
    },
  );
  test(
    'same-day future scheduled task is not due and quota subtracts today attempts',
    () async {
      final add = await repo.addReview(
        'add',
        'ship',
        StudySkill.pronunciation,
        source: 'user_request',
      );
      final point = (await repo.load()).reviews.single;
      await repo.schedule(
        'schedule',
        add.pointId!,
        now.add(const Duration(hours: 10)),
        expectedRevision: point.revision,
      );
      final before = StudyService(
        repo,
        catalog,
        clock: () => now,
      ).dailyQueue(await repo.load());
      expect(before.where((t) => t.reviewId != null), isEmpty);
      await attempt('a');
      final after = StudyService(
        repo,
        catalog,
        clock: () => now,
      ).dailyQueue(await repo.load());
      expect(after.length, lessThan(before.length));
    },
  );
  test(
    'unselected favorite and familiar status do not enroll a word',
    () async {
      await repo.updateWord('fav', 'abandon', favorite: true);
      expect((await repo.load()).progress['abandon']!.selected, false);
      expect(
        StudyService(
          repo,
          catalog,
          clock: () => now,
        ).dailyQueue(await repo.load()).any((t) => t.wordId == 'abandon'),
        false,
      );
    },
  );
  test('nonmeasurement sources cannot assert independent success', () async {
    for (final source in [
      'exposure',
      'reading_supplement',
      'practice_completed',
    ]) {
      await expectLater(
        attempt(source, source: source),
        throwsA(isA<StudyFailure>()),
      );
    }
    expect((await repo.load()).attemptCount, 0);
  });
  test(
    'lease revoked after mutation before commit rolls back session receipt and outbox',
    () async {
      await repo.saveSession({
        'tasks': [
          {'wordId': 'ship', 'skill': 'meaning'},
        ],
        'index': 0,
      });
      var checks = 0;
      await expectLater(
        repo.withCommandLease(
          () => ++checks == 1,
          () => repo.endSession('end'),
        ),
        throwsA(isA<StudyFailure>()),
      );
      expect((await repo.load()).session, isNotNull);
      expect(await repo.receipt('end'), isNull);
      expect(await repo.database.query('outbox'), isEmpty);
      final result = await repo.endSession('end');
      expect((await repo.endSession('end')).operationId, result.operationId);
    },
  );
  test(
    'invalid enums, negative FSRS state and mismatched evidence cannot replace database',
    () async {
      await attempt('a');
      await repo.updateWord('note', 'ship', note: '保留原库');
      final pristine = await repo.exportBackup();
      for (final change in [
        'enum',
        'stability',
        'cursor',
        'bad-step',
        'null-relearning',
        'negative-step',
        'out-of-range-step',
        'review-step',
      ]) {
        final backup = jsonDecode(jsonEncode(pristine)) as Map<String, dynamic>;
        final tables = backup['tables'] as Map;
        if (change == 'enum') {
          final row = (tables['preferences'] as List).single as Map;
          final prefs = jsonDecode(row['data'] as String) as Map;
          prefs['direction'] = 'bad';
          row['data'] = jsonEncode(prefs);
        } else {
          final row = (tables['memory_states'] as List).single as Map;
          if (change == 'cursor') {
            row['evidence_cursor'] = 'missing';
          } else {
            final card = jsonDecode(row['card'] as String) as Map;
            if (change == 'stability') {
              card['stability'] = -1;
            } else if (change == 'bad-step') {
              card['step'] = 'bad';
            } else if (change == 'null-relearning') {
              card['state'] = 3;
              card['step'] = null;
            } else if (change == 'negative-step') {
              card['state'] = 1;
              card['step'] = -1;
            } else if (change == 'review-step') {
              card['state'] = 2;
              card['step'] = 0;
            } else {
              card['state'] = 3;
              card['step'] = 1;
            }
            row['card'] = jsonEncode(card);
          }
        }
        await expectLater(
          repo.restoreBackup(backup),
          throwsA(isA<StudyFailure>()),
        );
        expect((await repo.load()).progress['ship']!.note, '保留原库');
      }
      await repo.restoreBackup(pristine);
    },
  );
  test(
    'tool writes reject Chinese and English negative/query intents and stale proposals',
    () async {
      final tools = StudyTools(repo, catalog, clock: () => now);
      StudyToolContext ctx(String id, String text) => StudyToolContext(
        commandId: id,
        userText: text,
        isCurrent: () => true,
        focusId: 'ship',
      );
      for (final text in [
        '不要修改计划',
        'do not activate the plan',
        'what is my plan?',
      ]) {
        expect(
          (await tools.invoke(
            'study_plan_activate',
            {},
            ctx(text, text),
          ))['status'],
          'rejected',
        );
      }
      final proposed = await tools.invoke('study_plan_propose', {
        'new_limit': 5,
      }, ctx('propose', '帮我制订计划'));
      await repo.updatePreferences('manual', {
        'newLimit': 10,
      }, expectedRevision: 0);
      expect(
        (await tools.invoke('study_plan_activate', {
          'proposal_id': proposed['proposal_id'],
        }, ctx('activate', '确认这个计划')))['code'],
        'VERSION_CONFLICT',
      );
    },
  );
  test(
    'actual cross-turn add and trusted recent contribution undo preserve unrelated history',
    () async {
      final tools = StudyTools(repo, catalog, clock: () => now);
      StudyToolContext ctx(String id, String text) => StudyToolContext(
        commandId: id,
        userText: text,
        isCurrent: () => true,
        focusId: 'ship',
      );
      final other = await repo.addReview(
        'other',
        'ship',
        StudySkill.pronunciation,
        source: 'user_request',
      );
      final add = await tools.invoke(
        'study_review_point_add',
        {},
        ctx('add', '这个词明天练发音'),
      );
      expect(add['status'], 'committed');
      final info = await tools.invoke(
        'study_feedback_list',
        {},
        ctx('info', '查看反馈'),
      );
      expect(info['recentUndoableOperationId'], add['operation_id']);
      expect(
        (await tools.invoke(
          'study_review_point_undo',
          {},
          ctx('deny', '不要撤销刚才'),
        ))['status'],
        'rejected',
      );
      expect(
        (await tools.invoke(
          'study_review_point_undo',
          {},
          ctx('undo', '撤销刚才'),
        ))['status'],
        'committed',
      );
      final active = await repo.database.query(
        'contributions',
        where: 'active=1',
      );
      expect(active.single['operation_id'], other.operationId);
    },
  );
  test(
    'exam public snapshot never exposes frozen answers before publication',
    () async {
      await repo.startExam('start', {
        'pronunciationScoring': 'disabled',
        'items': [
          {'id': 'q', 'prompt': '船', 'answer': 'ship', 'explanation': '说明'},
        ],
      });
      final item =
          ((await repo.load()).exams.single['config']['items'] as List).single
              as Map;
      expect(item.containsKey('answer'), false);
      expect(item.containsKey('explanation'), false);
      await expectLater(attempt('a'), throwsA(isA<StudyFailure>()));
    },
  );
  test(
    'English command phrases use frozen this-word focus and how-to questions never write',
    () async {
      final tools = StudyTools(
        repo,
        catalog,
        audioPlayer: (text, lease) async => lease() && text == 'ship',
      );
      StudyToolContext ctx(String id, String text) => StudyToolContext(
        commandId: id,
        userText: text,
        isCurrent: () => true,
        focusId: 'ship',
      );
      for (final text in [
        'I want to add this word',
        'Please add this word to review',
      ]) {
        final result = await tools.invoke(
          'study_review_point_add',
          {},
          ctx(text, text),
        );
        expect(result['word_id'], 'ship');
      }
      for (final text in [
        'Please read this word',
        'Please pronounce this word',
        'Play this word',
      ]) {
        final result = await tools.invoke(
          'study_audio_play',
          {},
          ctx(text, text),
        );
        expect(result['audio_status'], 'played');
      }
      final before = (await repo.database.query('contributions')).length;
      for (final text in ['请告诉我怎么把这个词加入复习', 'tell me how to add this word']) {
        expect(
          (await tools.invoke(
            'study_review_point_add',
            {},
            ctx(text, text),
          ))['status'],
          'rejected',
        );
      }
      expect((await repo.database.query('contributions')).length, before);
    },
  );
  test('ten-minute schedule budget refuses fourth three-minute task', () async {
    await repo.updatePreferences('budget', {
      'budgetMinutes': 10,
    }, expectedRevision: 0);
    for (var i = 0; i < 4; i++) {
      final add = await repo.addReview(
        'add$i',
        ['ship', 'journey', 'transfer', 'resilient'][i],
        StudySkill.pronunciation,
        source: 'user_request',
      );
      final point = (await repo.load()).reviews.firstWhere(
        (p) => p.id == add.pointId,
      );
      final future = repo.schedule(
        'schedule$i',
        point.id,
        now.add(const Duration(days: 1)),
        expectedRevision: point.revision,
      );
      if (i < 3) {
        await future;
      } else {
        await expectLater(future, throwsA(isA<StudyFailure>()));
      }
    }
  });
  test(
    'malformed published score results cannot replace valid current database',
    () async {
      final exam = await repo.startExam('start', {
        'pronunciationScoring': 'disabled',
        'items': [
          {'id': 'q', 'prompt': '船', 'answer': 'ship'},
        ],
      });
      final id = exam.values['exam_id'] as String;
      await repo.submitExam('submit', id, {'q': 'ship'});
      await repo.gradeExam('grade', id);
      await repo.publishExam('publish', id);
      final original = await repo.exportBackup();
      for (final value in [
        null,
        {
          'id': 'q',
          'correct': true,
          'answer': 'ship',
          'reference': 'wrong',
          'explanation': '',
        },
      ]) {
        final backup = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
        final row = (backup['tables']['exams'] as List).single as Map;
        final grade = jsonDecode(row['grade'] as String) as Map;
        grade['results'] = [value];
        row['grade'] = jsonEncode(grade);
        await expectLater(
          repo.restoreBackup(backup),
          throwsA(isA<StudyFailure>()),
        );
        expect((await repo.load()).exams.single['grade']['score'], 1);
      }
    },
  );
  test(
    'explicit command objects may be genuine stopword headwords while reference stays frozen',
    () async {
      final tools = StudyTools(repo, catalog);
      for (final entry in {
        'can': '把 can 加入复习',
        'read': 'add read to review',
      }.entries) {
        final result = await tools.invoke(
          'study_review_point_add',
          {'word_id': entry.key},
          StudyToolContext(
            commandId: entry.key,
            userText: entry.value,
            isCurrent: () => true,
            focusId: 'ship',
          ),
        );
        expect(result['status'], 'committed');
        expect(result['word_id'], entry.key);
      }
      final result = await tools.invoke(
        'study_review_point_add',
        {},
        const StudyToolContext(
          commandId: 'reference',
          userText: 'I want to add this word to my vocabulary book',
          isCurrent: _valid,
          focusId: 'ship',
        ),
      );
      expect(result['word_id'], 'ship');
    },
  );
}

bool _valid() => true;
