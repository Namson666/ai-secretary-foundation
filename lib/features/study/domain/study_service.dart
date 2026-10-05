import 'dart:math';
import 'study_models.dart';
import 'study_repository.dart';

class StudyTask {
  const StudyTask(this.wordId, this.skill, {this.reviewId});
  final String wordId;
  final StudySkill skill;
  final String? reviewId;
}

class StudyService {
  StudyService(this.repository, this.catalog, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final StudyRepository repository;
  final StudyCatalog catalog;
  final DateTime Function() clock;
  static DateTime chinaDay(DateTime date) {
    final china = date.toUtc().add(const Duration(hours: 8));
    return DateTime.utc(
      china.year,
      china.month,
      china.day,
    ).subtract(const Duration(hours: 8));
  }

  List<StudyTask> dailyQueue(StudySnapshot snapshot, {Random? random}) {
    final now = clock().toUtc();
    final due =
        snapshot.reviews
            .where(
              (r) =>
                  r.status == 'planned' &&
                  r.dueAt != null &&
                  !r.dueAt!.isAfter(now) &&
                  snapshot.progress[r.wordId]?.disposition ==
                      WordDisposition.active,
            )
            .toList()
          ..sort((a, b) => a.dueAt!.compareTo(b.dueAt!));
    final tasks = due
        .map((r) => StudyTask(r.wordId, r.skill, reviewId: r.id))
        .toList();
    final book = catalog.books.firstWhere(
      (b) => b.id == snapshot.preferences.bookId,
      orElse: () => catalog.books.first,
    );
    final candidates = book.wordIds
        .where(
          (id) =>
              snapshot.progress[id]?.selected == true &&
              snapshot.progress[id]?.introduced == false &&
              snapshot.progress[id]?.disposition == WordDisposition.active &&
              !due.any((r) => r.wordId == id),
        )
        .toList();
    if (snapshot.preferences.order == 'random') candidates.shuffle(random);
    final skill = switch (snapshot.preferences.direction) {
      'spell' => StudySkill.spelling,
      'listen' => StudySkill.listening,
      'cn-en' => StudySkill.production,
      _ => StudySkill.meaning,
    };
    final remaining = max(
      0,
      min(
            snapshot.preferences.dailyLimit,
            snapshot.preferences.budgetMinutes ~/ 3,
          ) -
          snapshot.todayAttempts,
    );
    tasks.addAll(
      candidates
          .take(
            max(
              0,
              snapshot.preferences.newLimit - snapshot.todayNewIntroductions,
            ),
          )
          .map((id) => StudyTask(id, skill)),
    );
    return List.unmodifiable(tasks.take(remaining));
  }

  Future<CommitReceipt> addFrozenReview(
    String commandId,
    String capturedWordId, {
    StudySkill skill = StudySkill.pronunciation,
  }) {
    if (!catalog.words.containsKey(capturedWordId)) {
      throw const StudyFailure('INVALID_ARGUMENT', '无法定位单词，请明确对象。');
    }
    return repository.addReview(
      commandId,
      capturedWordId,
      skill,
      source: 'user_request',
      requestedDue: chinaDay(
        clock(),
      ).add(const Duration(days: 1, hours: 19, minutes: 30)),
    );
  }
}
