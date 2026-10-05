import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/fsrs_scheduler.dart';
import '../data/sqlite_study_repository.dart';
import '../domain/study_models.dart';
import '../domain/study_analytics.dart';
import '../domain/study_repository.dart';
import '../domain/study_service.dart';

final studyCatalogProvider = FutureProvider<StudyCatalog>(
  (ref) async => StudyCatalog.fromJson(
    jsonDecode(await rootBundle.loadString('assets/study/vocabulary.json'))
        as Map<String, dynamic>,
  ),
);
final studyRepositoryProvider = FutureProvider<StudyRepository>((ref) async {
  final catalog = await ref.watch(studyCatalogProvider.future);
  final repository = await SqliteStudyRepository.open(
    catalog,
    Fsrs6Scheduler(),
  );
  ref.onDispose(() => unawaited(repository.close()));
  return repository;
});
final studyControllerProvider =
    AsyncNotifierProvider<StudyController, StudySnapshot>(StudyController.new);
String studyCommandId() =>
    'cmd_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';

class StudyController extends AsyncNotifier<StudySnapshot> {
  @override
  Future<StudySnapshot> build() async =>
      (await ref.watch(studyRepositoryProvider.future)).load();
  Future<bool> refresh() async {
    try {
      state = AsyncData(
        await (await ref.read(studyRepositoryProvider.future)).load(),
      );
      ref.read(studyRefreshNoticeProvider.notifier).clear();
      return true;
    } catch (error) {
      ref.read(studyRefreshNoticeProvider.notifier).set('记录已提交，显示刷新待重试。');
      return false;
    }
  }

  Future<CommitReceipt> commit(
    Future<CommitReceipt> Function(StudyRepository) action,
  ) async {
    final receipt = await action(
      await ref.read(studyRepositoryProvider.future),
    );
    final refreshed = await refresh();
    return refreshed
        ? receipt
        : CommitReceipt({
            ...receipt.values,
            'display_refresh_pending': true,
            'message': '${receipt.message} 显示刷新待重试。',
          });
  }
}

final studyServiceProvider = FutureProvider<StudyService>(
  (ref) async => StudyService(
    await ref.watch(studyRepositoryProvider.future),
    await ref.watch(studyCatalogProvider.future),
  ),
);

final studyAnalyticsProvider = FutureProvider<StudyAnalytics>((ref) async {
  ref.watch(studyControllerProvider);
  return (await ref.watch(studyRepositoryProvider.future)).getAnalytics();
});

final studyRefreshNoticeProvider =
    NotifierProvider<StudyRefreshNotice, String?>(StudyRefreshNotice.new);

class StudyRefreshNotice extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String message) => state = message;
  void clear() => state = null;
}

Future<Map<String, dynamic>> studyRefreshToolResult(
  Map<String, dynamic> result,
  Future<bool> Function() refresh,
) async {
  bool refreshed = false;
  try {
    refreshed = await refresh();
  } catch (_) {
    refreshed = false;
  }
  return refreshed
      ? result
      : {
          ...result,
          'display_refresh_pending': true,
          if (result['status'] == 'committed')
            'message': '${result['message']} 显示刷新待重试。',
        };
}
