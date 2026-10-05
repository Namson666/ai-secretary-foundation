import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ai_secretary/features/study/application/study_providers.dart';
import 'package:ai_secretary/features/study/data/fsrs_scheduler.dart';
import 'package:ai_secretary/features/study/data/sqlite_study_repository.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study/domain/study_service.dart';
import 'package:ai_secretary/features/study/domain/study_repository.dart';
import 'package:ai_secretary/features/study/presentation/learning_page.dart';
import 'package:ai_secretary/features/study/presentation/exam_page.dart';

class CheckpointGate implements StudyRepository {
  CheckpointGate(this.inner);
  final StudyRepository inner;
  Completer<void>? gate;
  int ended = 0;
  @override
  Future<StudySnapshot> load() => inner.load();
  @override
  Future<CommitReceipt?> receipt(String id) => inner.receipt(id);
  @override
  Future<CommitReceipt> recordAttempt(String id, AttemptEvidence e) =>
      inner.recordAttempt(id, e);
  @override
  Future<void> saveSession(Map<String, dynamic>? session) async {
    if (session?['submitted'] == true) await gate?.future;
    await inner.saveSession(session);
  }

  @override
  Future<CommitReceipt> endSession(String id) async {
    ended++;
    return inner.endSession(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  sqfliteFfiInit();
  late SqliteStudyRepository repo;
  late StudyCatalog catalog;
  late Directory temp;
  setUp(() async {
    catalog = StudyCatalog(
      [const StudyWord(id: 'ship', word: 'ship', meaning: '船')],
      [
        StudyBook(
          id: 'daily',
          title: 'Daily',
          subtitle: 'test',
          wordIds: ['ship'],
        ),
      ],
    );
    temp = await Directory.systemTemp.createTemp('study-write-');
    repo = await SqliteStudyRepository.open(
      catalog,
      Fsrs6Scheduler(fuzz: false),
      factory: databaseFactoryFfiNoIsolate,
      databasePath: '${temp.path}/study.sqlite',
    );
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<void> mount(
    WidgetTester tester,
    Widget page, {
    StudyRepository? repository,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studyCatalogProvider.overrideWith((ref) async => catalog),
          studyRepositoryProvider.overrideWith(
            (ref) async => repository ?? repo,
          ),
        ],
        child: MaterialApp(home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text).last);
    await tester.tap(find.text(text).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'failed exam draft and submit remain retryable without permanent busy lock',
    (tester) async {
      await repo.startExam('start', {
        'pronunciationScoring': 'disabled',
        'items': [
          {'id': 'q', 'prompt': '船', 'answer': 'ship'},
        ],
      });
      await mount(tester, const StudyExamPage());
      await repo.database.execute(
        "CREATE TRIGGER draft_failure BEFORE UPDATE ON exams BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await tester.enterText(find.byType(TextFormField), 'ship');
      await tester.pumpAndSettle();
      await tap(tester, '确认交卷');
      expect((await repo.load()).exams.single['status'], 'active');
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认交卷'))
            .onPressed,
        isNotNull,
      );
      await repo.database.execute('DROP TRIGGER draft_failure');
      await tap(tester, '确认交卷');
      expect((await repo.load()).exams.single['status'], 'submitted');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'end waits for queued checkpoint writes and cannot revive completed session',
    (tester) async {
      final proxy = CheckpointGate(repo);
      await mount(
        tester,
        const StudyLearningPage(tasks: [StudyTask('ship', StudySkill.meaning)]),
        repository: proxy,
      );
      await tap(tester, '我已独立想起，核对答案');
      proxy.gate = Completer<void>();
      await tap(tester, '独立想起');
      await tester.ensureVisible(find.text('完成本轮'));
      await tester.tap(find.text('完成本轮'));
      await tester.pump();
      expect(proxy.ended, 0);
      proxy.gate!.complete();
      await tester.pumpAndSettle();
      expect(proxy.ended, 1);
      expect((await repo.load()).session, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'revealed objective answer cannot replace failed first evidence on retry',
    (tester) async {
      await mount(
        tester,
        const StudyLearningPage(
          tasks: [StudyTask('ship', StudySkill.spelling)],
        ),
      );
      await repo.database.execute(
        "CREATE TRIGGER attempt_failure BEFORE INSERT ON attempts BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await tester.enterText(find.byType(TextField), 'shp');
      await tap(tester, '提交答案');
      expect((await repo.load()).attemptCount, 0);
      expect(tester.widget<TextField>(find.byType(TextField)).readOnly, true);
      tester.widget<TextField>(find.byType(TextField)).controller!.text =
          'ship';
      await repo.database.execute('DROP TRIGGER attempt_failure');
      await tap(tester, '重试保存首次作答');
      final payload =
          jsonDecode(
                (await repo.database.query('attempts')).single['payload']
                    as String,
              )
              as Map;
      expect(payload['answer'], 'shp');
      expect(payload['correct'], false);
      expect(payload['grade'], 'again');
      expect((await repo.load()).independentSuccessCount, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
