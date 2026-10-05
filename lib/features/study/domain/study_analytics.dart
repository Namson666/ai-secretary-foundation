import 'study_models.dart';

class SkillStatistics {
  const SkillStatistics({
    required this.attempts,
    required this.independentSuccesses,
    required this.hintedAttempts,
    required this.forgottenAttempts,
  });
  final int attempts, independentSuccesses, hintedAttempts, forgottenAttempts;
}

class MemoryStatistics {
  const MemoryStatistics({
    required this.wordId,
    required this.skill,
    required this.stabilityDays,
    required this.difficulty,
    required this.dueAt,
    required this.lastReview,
    required this.recallForecast,
  });
  final String wordId;
  final StudySkill skill;
  final double stabilityDays, difficulty;
  final DateTime dueAt, lastReview;

  /// Model estimates at captured time + 0, 1, 3, 7, 14, 30 days, not observed personal correctness.
  final List<double> recallForecast;
}

class StudyAnalytics {
  const StudyAnalytics({
    required this.capturedAt,
    required this.bySkill,
    required this.dailyAttempts,
    required this.memories,
  });
  final DateTime capturedAt;
  final Map<StudySkill, SkillStatistics> bySkill;
  final Map<String, int> dailyAttempts;
  final List<MemoryStatistics> memories;
  static const forecastDays = [0, 1, 3, 7, 14, 30];
}
