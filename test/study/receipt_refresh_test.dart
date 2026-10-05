import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ai_secretary/features/study/application/study_providers.dart';
import 'package:ai_secretary/features/study/application/study_tools.dart';
import 'package:ai_secretary/features/study/data/fsrs_scheduler.dart';
import 'package:ai_secretary/features/study/data/sqlite_study_repository.dart';
import 'package:ai_secretary/features/study/domain/study_models.dart';
import 'package:ai_secretary/features/study/domain/study_repository.dart';

class RefreshFailureRepository implements StudyRepository {
  RefreshFailureRepository(this.inner);
  final SqliteStudyRepository inner;
  bool failRead = false;
  @override
  Future<StudySnapshot> load() {
    if (failRead) {
      throw const StudyFailure('STORAGE_FAILURE', 'injected read failure');
    }
    return inner.load();
  }

  @override
  Future<CommitReceipt> selectWords(String id, List<String> words) async {
    final receipt = await inner.selectWords(id, words);
    failRead = true;
    return receipt;
  }

  @override
  Future<T> withCommandLease<T>(
    bool Function() current,
    Future<T> Function() action,
  ) => inner.withCommandLease(current, action);
  @override
  Future<CommitReceipt> addReview(
    String id,
    String wordId,
    StudySkill skill, {
    required String source,
    DateTime? requestedDue,
  }) async {
    final receipt = await inner.addReview(
      id,
      wordId,
      skill,
      source: source,
      requestedDue: requestedDue,
    );
    failRead = true;
    return receipt;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  sqfliteFfiInit();
  late Directory temp;
  late SqliteStudyRepository repo;
  late RefreshFailureRepository wrapper;
  late StudyCatalog catalog;
  late ProviderContainer container;
  setUp(() async {
    catalog = StudyCatalog(
      [const StudyWord(id: 'ship', word: 'ship', meaning: '船')],
      [
        StudyBook(id: 'daily', title: 'daily', subtitle: '', wordIds: ['ship']),
      ],
    );
    temp = await Directory.systemTemp.createTemp('study-receipt-');
    repo = await SqliteStudyRepository.open(
      catalog,
      Fsrs6Scheduler(fuzz: false),
      factory: databaseFactoryFfi,
      databasePath: '${temp.path}/study.sqlite',
    );
    wrapper = RefreshFailureRepository(repo);
    container = ProviderContainer(
      overrides: [studyRepositoryProvider.overrideWith((_) async => wrapper)],
    );
    await container.read(studyControllerProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await repo.close();
    await temp.delete(recursive: true);
  });
  test(
    'UI controller preserves committed fact when followup display refresh fails',
    () async {
      final receipt = await container
          .read(studyControllerProvider.notifier)
          .commit((r) => r.selectWords('select', ['ship']));
      expect(receipt.committed, true);
      expect(receipt.values['display_refresh_pending'], true);
      expect(receipt.message, contains('显示刷新待重试'));
      expect(await repo.receipt('select'), isNotNull);
      expect(container.read(studyRefreshNoticeProvider), isNotNull);
      wrapper.failRead = false;
      expect(
        await container.read(studyControllerProvider.notifier).refresh(),
        true,
      );
      expect(container.read(studyRefreshNoticeProvider), isNull);
    },
  );
  test(
    'real tool commit remains committed through runtime result refresh failure',
    () async {
      final tools = StudyTools(wrapper, catalog);
      final result = await tools.invoke(
        'study_review_point_add',
        {},
        const StudyToolContext(
          commandId: 'tool',
          userText: '这个词明天练发音',
          focusId: 'ship',
          isCurrent: _current,
        ),
      );
      final delivered = await studyRefreshToolResult(
        result,
        container.read(studyControllerProvider.notifier).refresh,
      );
      expect(delivered['status'], 'committed');
      expect(delivered['operation_id'], result['operation_id']);
      expect(delivered['message'], contains('显示刷新待重试'));
      expect((await repo.load()).reviews.length, 1);
    },
  );
}

bool _current() => true;
