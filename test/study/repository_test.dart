import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ai_secretary/features/study/data/sqlite_study_repository.dart';
import 'package:ai_secretary/features/study/data/fsrs_scheduler.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study/domain/study_service.dart';

void main() {
  sqfliteFfiInit();
  late StudyCatalog catalog;
  late SqliteStudyRepository repo;
  late Directory temp;
  final now = DateTime.utc(2026, 10, 5, 14);
  setUp(() async {
    catalog = StudyCatalog.fromJson(
      jsonDecode(await File('assets/study/vocabulary.json').readAsString())
          as Map<String, dynamic>,
    );
    temp = await Directory.systemTemp.createTemp('study-domain-');
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
  test(
    'real preset catalog has four full browse scopes and distinct canonical IDs',
    () {
      expect(catalog.books.map((b) => b.wordIds.length), [
        1000,
        1500,
        1500,
        1500,
      ]);
      expect(catalog.words.length, 2474);
      expect(catalog.words['abandon']?.meaning, isNotEmpty);
    },
  );
  test(
    'same command returns same commit receipt while changed payload conflicts',
    () async {
      final first = await repo.addReview(
        'add-1',
        'ship',
        StudySkill.pronunciation,
        source: 'user_request',
      );
      final again = await repo.addReview(
        'add-1',
        'ship',
        StudySkill.pronunciation,
        source: 'user_request',
      );
      expect(again.operationId, first.operationId);
      expect(first.values['schedule_status'], 'pending');
      expect((await repo.database.query('contributions')).length, 1);
      await expectLater(
        repo.addReview(
          'add-1',
          'journey',
          StudySkill.pronunciation,
          source: 'user_request',
        ),
        throwsA(isA<StudyFailure>()),
      );
      expect((await repo.database.query('outbox')).length, 1);
    },
  );
  test(
    'transaction failure rolls back selection, command receipt and outbox atomically',
    () async {
      await repo.database.execute(
        "CREATE TRIGGER failure BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        repo.selectWords('failure', ['abandon']),
        throwsA(anything),
      );
      expect((await repo.load()).progress['abandon'], isNull);
      expect(await repo.receipt('failure'), isNull);
      await repo.database.execute('DROP TRIGGER failure');
      expect((await repo.selectWords('failure', ['abandon'])).committed, true);
    },
  );
  test(
    'cross-book selection, note and status survive reopening distinct English database',
    () async {
      await repo.selectWords('select', ['abandon']);
      await repo.updateWord(
        'note',
        'abandon',
        note: '自己的句子',
        disposition: WordDisposition.paused,
      );
      final before = await repo.load();
      await repo.updatePreferences('book', {
        'bookId': 'cet4',
      }, expectedRevision: before.preferences.revision);
      await repo.close();
      repo = await SqliteStudyRepository.open(
        catalog,
        Fsrs6Scheduler(fuzz: false),
        factory: databaseFactoryFfi,
        databasePath: '${temp.path}/study.sqlite',
        clock: () => now,
      );
      expect((await repo.load()).progress['abandon']?.note, '自己的句子');
      expect(
        (await repo.load()).progress['abandon']?.disposition,
        WordDisposition.paused,
      );
      expect((await repo.load()).preferences.bookId, 'cet4');
    },
  );
  test(
    'undo contribution preserves another and completed pronunciation history',
    () async {
      final a = await repo.addReview(
        'a',
        'ship',
        StudySkill.pronunciation,
        source: 'user_request',
      );
      final b = await repo.addReview(
        'b',
        'ship',
        StudySkill.pronunciation,
        source: 'user_request',
      );
      await repo.undo('undo-a', a.operationId);
      expect((await repo.load()).reviews.single.status, 'pending');
      await repo.recordAttempt(
        'speech',
        AttemptEvidence(
          attemptId: 'speech-1',
          wordId: 'ship',
          skill: StudySkill.pronunciation,
          grade: RecallGrade.good,
          independent: false,
          hinted: false,
          source: 'practice_completed',
          answer: '',
          reviewPointId: b.pointId,
        ),
      );
      await repo.undo('undo-b', b.operationId);
      expect((await repo.load()).reviews.single.status, 'done');
      expect((await repo.load()).attemptCount, 1);
      expect(await repo.database.query('memory_states'), isEmpty);
    },
  );
  test(
    'hinted attempt receives Again and skill states stay separate with persistent stable card IDs',
    () async {
      await repo.recordAttempt(
        'recall',
        const AttemptEvidence(
          attemptId: 'r1',
          wordId: 'ship',
          skill: StudySkill.meaning,
          grade: RecallGrade.hard,
          independent: false,
          hinted: true,
          source: 'user_self_report',
          answer: '',
        ),
      );
      await repo.recordAttempt(
        'spell',
        const AttemptEvidence(
          attemptId: 's1',
          wordId: 'ship',
          skill: StudySkill.spelling,
          grade: RecallGrade.good,
          independent: true,
          hinted: false,
          source: 'objective_text',
          answer: 'ship',
          correct: true,
        ),
      );
      final states = await repo.database.query('memory_states');
      expect(states.length, 2);
      expect(states.map((s) => s['card_id']).toSet().length, 2);
      final first = states.first;
      expect(first['model_version'], 'FSRS-6 / dart-fsrs 2.0.1');
      expect(jsonDecode(first['log'] as String)['rating'], 1);
      await expectLater(
        repo.recordAttempt(
          'invalid',
          const AttemptEvidence(
            attemptId: 'bad',
            wordId: 'ship',
            skill: StudySkill.meaning,
            grade: RecallGrade.hard,
            independent: true,
            hinted: true,
            source: 'user_self_report',
            answer: '',
          ),
        ),
        throwsA(isA<StudyFailure>()),
      );
      expect((await repo.load()).attemptCount, 2);
    },
  );
  test(
    'future pending reviews do not enter today and stale plans cannot overwrite preferences',
    () async {
      final result = await StudyService(
        repo,
        catalog,
        clock: () => now,
      ).addFrozenReview('tomorrow', 'ship');
      var state = await repo.load();
      final point = state.reviews.single;
      await repo.schedule(
        'schedule',
        result.pointId!,
        StudyService.chinaDay(
          now,
        ).add(const Duration(days: 1, hours: 19, minutes: 30)),
        expectedRevision: point.revision,
      );
      state = await repo.load();
      expect(
        StudyService(
          repo,
          catalog,
          clock: () => now,
        ).dailyQueue(state).where((t) => t.reviewId != null),
        isEmpty,
      );
      await repo.updatePreferences('plan', {
        'newLimit': 0,
      }, expectedRevision: state.preferences.revision);
      await expectLater(
        repo.updatePreferences('stale', {
          'newLimit': 20,
        }, expectedRevision: state.preferences.revision),
        throwsA(isA<StudyFailure>()),
      );
      expect(
        StudyService(
          repo,
          catalog,
          clock: () => now,
        ).dailyQueue(await repo.load()),
        isEmpty,
      );
    },
  );
  test(
    'exam freezes answer policy and separates submit, grade and publish',
    () async {
      final run = await repo.startExam('start', {
        'pronunciationScoring': 'disabled',
        'items': [
          {'id': 'q1', 'prompt': '拼写：船', 'answer': 'ship'},
        ],
      });
      final id = run.values['exam_id'] as String;
      await repo.submitExam('submit', id, {'q1': 'ship'});
      expect((await repo.load()).exams.single.containsKey('grade'), false);
      await repo.gradeExam('grade', id);
      expect((await repo.load()).exams.single.containsKey('grade'), false);
      await repo.publishExam('publish', id);
      expect(((await repo.load()).exams.single['grade'] as Map)['score'], 1);
    },
  );
  test(
    'backup restore is English-only and preserves real evidence and receipts',
    () async {
      await repo.selectWords('select', ['abandon']);
      await repo.updateWord('note', 'abandon', note: '长期保留');
      final backup = await repo.exportBackup();
      await repo.updateWord('change', 'abandon', note: '临时');
      await repo.restoreBackup(backup);
      expect((await repo.load()).progress['abandon']?.note, '长期保留');
      expect(await repo.receipt('select'), isNotNull);
      await expectLater(
        repo.restoreBackup({...backup, 'namespace': 'fitness'}),
        throwsA(isA<StudyFailure>()),
      );
    },
  );
}
