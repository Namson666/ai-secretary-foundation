import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ai_secretary/features/study/application/study_providers.dart';
import 'package:ai_secretary/features/study/data/fsrs_scheduler.dart';
import 'package:ai_secretary/features/study/data/sqlite_study_repository.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study/presentation/learning_page.dart';
import 'package:ai_secretary/features/study/presentation/library_page.dart';

void main() {
  sqfliteFfiInit();
  late StudyCatalog catalog;
  late SqliteStudyRepository repo;
  late Directory temp;
  setUp(() async {
    catalog = StudyCatalog(
      [
        const StudyWord(id: 'apple', word: 'apple', meaning: '苹果'),
        const StudyWord(id: 'ship', word: 'ship', meaning: '船'),
        const StudyWord(id: 'journey', word: 'journey', meaning: '旅程'),
      ],
      [
        StudyBook(
          id: 'daily',
          title: '日常',
          subtitle: 'test',
          wordIds: ['apple', 'ship', 'journey'],
        ),
      ],
    );
    temp = await Directory.systemTemp.createTemp('study-ui-');
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
  Future<void> mount(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          studyCatalogProvider.overrideWith((ref) async => catalog),
          studyRepositoryProvider.overrideWith((ref) async => repo),
        ],
        child: MaterialApp(home: Scaffold(body: page)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> session() => {
    'tasks': [
      {'wordId': 'apple', 'skill': 'meaning'},
      {'wordId': 'ship', 'skill': 'meaning'},
      {'wordId': 'journey', 'skill': 'meaning'},
    ],
    'index': 1,
    'revealed': true,
    'hinted': false,
    'claimed': true,
    'submitted': false,
    'reading': false,
    'answer': '船',
    'attemptId': 'old-ship',
  };
  testWidgets(
    'resume removing preceding paused task keeps current word and evidence identity',
    (tester) async {
      await repo.saveSession(session());
      await repo.updateWord(
        'pause',
        'apple',
        disposition: WordDisposition.paused,
      );
      await mount(tester, const StudyLearningPage.resume());
      expect(find.text('ship'), findsOneWidget);
      expect(find.text('1 / 2 · 英→中回忆'), findsOneWidget);
      final saved = (await repo.load()).session!;
      expect(saved['attemptId'], 'old-ship');
      expect(saved['claimed'], true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'resume removing current word clears revealed answers and independent claim',
    (tester) async {
      await repo.saveSession(session());
      await repo.updateWord(
        'pause',
        'ship',
        disposition: WordDisposition.paused,
      );
      await mount(tester, const StudyLearningPage.resume());
      expect(find.text('apple'), findsOneWidget);
      expect(find.text('点击显示答案'), findsOneWidget);
      final saved = (await repo.load()).session!;
      expect(saved['attemptId'], isNot('old-ship'));
      expect(saved['claimed'], false);
      expect(saved['revealed'], false);
      expect(saved['answer'], '');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'sequential selection stays within search and repeated pick respects remaining quota',
    (tester) async {
      await repo.database.delete('word_state');
      await mount(tester, const StudyBookPage(bookId: 'daily'));
      await tester.enterText(find.byType(TextField).first, 'ship');
      await tester.pump();
      await tester.tap(find.text('顺选 20'));
      await tester.pump();
      expect(find.text('确认加入 1 个词'), findsOneWidget);
      await tester.tap(find.text('随机选词'));
      await tester.pump();
      expect(find.text('确认加入 1 个词'), findsOneWidget);
      await tester.tap(find.text('确认加入 1 个词'));
      await tester.pumpAndSettle();
      expect((await repo.load()).progress.keys, ['ship']);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'personal short text confirms selected words and dialog animation retains controller safely',
    (tester) async {
      await repo.database.delete('word_state');
      await mount(tester, const StudyLibraryPage());
      await tester.scrollUntilVisible(
        find.text('从个人短文选词'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('从个人短文选词'));
      await tester.tap(find.text('从个人短文选词'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        'A ship begins a journey.',
      );
      await tester.tap(find.text('确认加入匹配词'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect((await repo.load()).progress.keys.toSet(), {'ship', 'journey'});
      await tester.pumpWidget(const SizedBox());
    },
  );
}
