import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as paths;
import 'package:ai_secretary/features/study/application/study_providers.dart';
import 'package:ai_secretary/features/study/application/study_tools.dart';
import 'package:ai_secretary/features/study/data/sqlite_study_repository.dart';
import 'package:ai_secretary/features/study/data/fsrs_scheduler.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study/domain/study_service.dart';
import 'package:ai_secretary/features/study/presentation/library_page.dart';
import 'package:ai_secretary/features/study/presentation/learning_page.dart';
import 'package:ai_secretary/features/study/presentation/exam_page.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late StudyCatalog catalog;
  late SqliteStudyRepository repository;
  late String dbPath;
  setUp(() async {
    catalog = StudyCatalog.fromJson(
      jsonDecode(await rootBundle.loadString('assets/study/vocabulary.json'))
          as Map<String, dynamic>,
    );
    dbPath = paths.join(await getDatabasesPath(), 'study-integration.sqlite');
    await deleteDatabase(dbPath);
    repository = await SqliteStudyRepository.open(
      catalog,
      Fsrs6Scheduler(fuzz: false),
      databasePath: dbPath,
    );
  });
  tearDown(() async {
    await repository.close();
    await deleteDatabase(dbPath);
  });
  Future<void> open(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studyCatalogProvider.overrideWith((_) async => catalog),
          studyRepositoryProvider.overrideWith((_) async => repository),
        ],
        child: MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    final finder = find.text(text).last;
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'native SQLite selected search → reverse hidden card → hint → saved Again → reopen',
    (tester) async {
      expect(catalog.books.map((b) => b.wordIds.length), [
        1000,
        1500,
        1500,
        1500,
      ]);
      await repository.database.delete('word_state');
      await open(tester, const StudyBookPage(bookId: 'cet4'));
      await tester.enterText(find.byType(TextField).first, 'ability');
      await tester.pumpAndSettle();
      await tap(tester, '顺选 20');
      await tap(tester, '确认加入 1 个词');
      expect((await repository.load()).progress['ability']?.selected, true);
      await open(
        tester,
        const StudyLearningPage(
          tasks: [StudyTask('ability', StudySkill.production)],
        ),
      );
      expect(find.text('ability'), findsNothing);
      expect(find.text('点击显示答案'), findsOneWidget);
      await tap(tester, '点击显示答案');
      expect(find.text('ability'), findsWidgets);
      final independent = find.widgetWithText(FilledButton, '独立想起');
      expect(tester.widget<FilledButton>(independent).onPressed, isNull);
      await tap(tester, '忘记 / 没想起');
      expect((await repository.load()).attemptCount, 1);
      expect((await repository.load()).independentSuccessCount, 0);
      await tester.pumpWidget(const SizedBox());
      await repository.close();
      repository = await SqliteStudyRepository.open(
        catalog,
        Fsrs6Scheduler(fuzz: false),
        databasePath: dbPath,
      );
      expect((await repository.load()).attemptCount, 1);
      expect((await repository.load()).progress['ability']!.introduced, true);
      final memory = (await repository.database.query('memory_states')).single;
      expect(memory['skill'], 'production');
      expect(jsonDecode(memory['log'] as String)['rating'], 1);
    },
  );
  testWidgets(
    'native frozen Agent contribution → committed receipt → schedule → undo preserves evidence',
    (tester) async {
      final tools = StudyTools(repository, catalog);
      const context = StudyToolContext(
        commandId: 'native-voice',
        userText: '这个词明天练发音',
        focusId: 'ship',
        isCurrent: _current,
      );
      final result = await tools.invoke('study_review_point_add', {}, context);
      expect(result['status'], 'committed');
      expect(result['word_id'], 'ship');
      final snapshot = await repository.load();
      final point = snapshot.reviews.firstWhere(
        (r) => r.id == result['point_id'],
      );
      await repository.schedule(
        'native-schedule',
        point.id,
        DateTime.now().toUtc().add(const Duration(days: 1)),
        expectedRevision: point.revision,
      );
      expect((await repository.load()).reviews.single.status, 'planned');
      await tools.invoke(
        'study_review_point_undo',
        {},
        const StudyToolContext(
          commandId: 'native-undo',
          userText: '撤销刚才',
          focusId: 'journey',
          isCurrent: _current,
        ),
      );
      expect((await repository.load()).reviews.single.status, 'cancelled');
      expect((await repository.database.query('commands')).length, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'native exam draft survives widget recreation and grade remains private until publish',
    (tester) async {
      final started = await repository.startExam('exam-start', {
        'pronunciationScoring': 'disabled',
        'items': [
          {
            'id': 'ship',
            'prompt': '船',
            'answer': 'ship',
            'explanation': 'n. 船',
          },
        ],
      });
      final examId = started.values['exam_id'] as String;
      await open(tester, const StudyExamPage());
      await tester.enterText(find.byType(TextFormField), 'ship');
      await tester.pumpAndSettle();
      expect((await repository.load()).exams.single['answers']['ship'], 'ship');
      await tester.pumpWidget(const SizedBox());
      await open(tester, const StudyExamPage());
      expect(find.text('ship'), findsOneWidget);
      await tap(tester, '确认交卷');
      expect((await repository.load()).exams.single['status'], 'submitted');
      expect(
        (await repository.load()).exams.single.containsKey('grade'),
        false,
      );
      await tap(tester, '完成客观评分');
      expect((await repository.load()).exams.single['status'], 'graded');
      expect(find.text('1 / 1'), findsNothing);
      await tap(tester, '发布本场成绩');
      expect((await repository.load()).exams.single['grade']['score'], 1);
      expect(find.text('1 / 1'), findsOneWidget);
      expect((await repository.load()).exams.single['id'], examId);
      await tester.pumpWidget(const SizedBox());
    },
  );
}

bool _current() => true;
