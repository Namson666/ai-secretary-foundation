import 'package:fsrs/fsrs.dart' as fsrs;
import '../domain/review_scheduler.dart';
import '../domain/study_models.dart';

class Fsrs6Scheduler implements ReviewScheduler {
  Fsrs6Scheduler({bool fuzz = true})
    : scheduler = fsrs.Scheduler(enableFuzzing: fuzz, desiredRetention: 0.9);
  final fsrs.Scheduler scheduler;
  @override
  String get version => 'FSRS-6 / dart-fsrs 2.0.1';
  @override
  bool isValidStoredCard(Map<String, dynamic> card) {
    try {
      if (card['cardId'] is! int ||
          card['state'] is! int ||
          card['stability'] is! num ||
          card['difficulty'] is! num ||
          !(card['stability'] as num).isFinite ||
          !(card['difficulty'] as num).isFinite ||
          (card['stability'] as num) <= 0 ||
          (card['difficulty'] as num) < 1 ||
          (card['difficulty'] as num) > 10) {
        return false;
      }
      final state = fsrs.State.fromValue(card['state'] as int);
      final step = card['step'];
      if (state == fsrs.State.review) {
        if (step != null) return false;
      } else {
        final steps = state == fsrs.State.learning
            ? scheduler.learningSteps
            : scheduler.relearningSteps;
        if (step is! int || step < 0 || step >= steps.length) return false;
      }
      final restored = fsrs.Card.fromMap({
        ...card,
        'stability': (card['stability'] as num).toDouble(),
        'difficulty': (card['difficulty'] as num).toDouble(),
      });
      return restored.due.isUtc && restored.lastReview?.isUtc == true;
    } catch (_) {
      return false;
    }
  }

  @override
  double retrievability(Map<String, dynamic> card, DateTime at) =>
      scheduler.getCardRetrievability(
        fsrs.Card.fromMap({
          ...card,
          'stability': (card['stability'] as num).toDouble(),
          'difficulty': (card['difficulty'] as num).toDouble(),
        }),
        currentDateTime: at.toUtc(),
      );
  @override
  MemoryUpdate review(
    Map<String, dynamic>? previous,
    RecallGrade grade,
    DateTime at, {
    required int cardId,
  }) {
    final map = previous == null
        ? null
        : {
            ...previous,
            'stability': (previous['stability'] as num?)?.toDouble(),
            'difficulty': (previous['difficulty'] as num?)?.toDouble(),
          };
    final card = map == null
        ? fsrs.Card(cardId: cardId, due: at.toUtc())
        : fsrs.Card.fromMap(map);
    final rating = switch (grade) {
      RecallGrade.again => fsrs.Rating.again,
      RecallGrade.hard => fsrs.Rating.hard,
      RecallGrade.good => fsrs.Rating.good,
      RecallGrade.easy => fsrs.Rating.easy,
    };
    final reviewed = scheduler.reviewCard(
      card,
      rating,
      reviewDateTime: at.toUtc(),
    );
    return MemoryUpdate(
      card: reviewed.card.toMap(),
      log: {
        ...reviewed.reviewLog.toMap(),
        'parameters': scheduler.parameters,
        'desiredRetention': scheduler.desiredRetention,
        'parameterVersion': 'default-21-v2.0.1',
      },
      dueAt: reviewed.card.due,
      modelVersion: version,
    );
  }
}
