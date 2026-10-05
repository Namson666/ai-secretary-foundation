import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ai_secretary/features/study/application/study_providers.dart';
import 'package:ai_secretary/features/study/domain/study_analytics.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study/domain/study_repository.dart';
import 'package:ai_secretary/features/study/presentation/profile_page.dart';
import 'package:ai_secretary/features/study/presentation/statistics_page.dart';

StudySnapshot _snapshot() => StudySnapshot(
  preferences: const StudyPreferences(),
  progress: {},
  reviews: [],
  attemptCount: 0,
  independentSuccessCount: 0,
  todayAttempts: 0,
  todayNewIntroductions: 0,
  weekAttempts: {},
  session: null,
  exams: [],
);

class _Controller extends StudyController {
  @override
  Future<StudySnapshot> build() async => _snapshot();
}

class _Repository implements StudyRepository {
  int restorations = 0;
  @override
  Future<StudySnapshot> load() async => _snapshot();
  @override
  Future<void> restoreBackup(Map<String, dynamic> backup) async {
    restorations++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

StudyAnalytics _analytics({bool hasMemory = false}) => StudyAnalytics(
  capturedAt: DateTime.utc(2026, 10, 5),
  bySkill: {},
  dailyAttempts: {},
  memories: hasMemory
      ? [
          MemoryStatistics(
            wordId: 'apple',
            skill: StudySkill.meaning,
            stabilityDays: 10,
            difficulty: 5,
            dueAt: DateTime.utc(2026, 10, 6),
            lastReview: DateTime.utc(2026, 10, 4),
            recallForecast: [0.7, 0.6, 0.5, 0.4, 0.3, 0.2],
          ),
        ]
      : [],
);

Future<void> _open(
  WidgetTester tester,
  Widget page,
  _Repository repository, {
  bool hasMemory = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        studyControllerProvider.overrideWith(_Controller.new),
        studyRepositoryProvider.overrideWith((ref) async => repository),
        studyAnalyticsProvider.overrideWith(
          (ref) async => _analytics(hasMemory: hasMemory),
        ),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(body: page),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _restoreDialog(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(find.text('从备份恢复'), 300);
  await tester.ensureVisible(find.text('从备份恢复'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('从备份恢复'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.text('检查备份'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no practice produces a truthful forecast empty state', (
    tester,
  ) async {
    await _open(tester, const StudyStatisticsPage(), _Repository());
    expect(find.text('还没有记忆预测'), findsOneWidget);
    expect(find.text('FSRS-6 模型预测'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skill filtering removes and restores the actual forecast', (
    tester,
  ) async {
    await _open(
      tester,
      const StudyStatisticsPage(),
      _Repository(),
      hasMemory: true,
    );
    expect(find.text('70%'), findsOneWidget);
    await tester.tap(find.text('全部技能'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拼写'));
    await tester.pumpAndSettle();
    expect(find.text('还没有记忆预测'), findsOneWidget);
    await tester.tap(find.text('拼写'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部技能'));
    await tester.pumpAndSettle();
    expect(find.text('70%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid pasted backup never invokes restore', (tester) async {
    final repository = _Repository();
    await _open(tester, const StudyProfilePage(), repository);
    await _restoreDialog(
      tester,
      '{"namespace":"health","schema":1,"tables":{}}',
    );
    expect(repository.restorations, 0);
    expect(find.text('备份格式无效，请粘贴完整英语学习备份。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('backup preview cancels without replacing current study data', (
    tester,
  ) async {
    final repository = _Repository();
    await _open(tester, const StudyProfilePage(), repository);
    await _restoreDialog(
      tester,
      '{"namespace":"english","schema":1,"tables":{"word_state":[],"attempts":[],"review_points":[],"exams":[]}}',
    );
    expect(find.text('确认恢复学习备份'), findsOneWidget);
    expect(repository.restorations, 0);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repository.restorations, 0);
    expect(tester.takeException(), isNull);
  });
}
