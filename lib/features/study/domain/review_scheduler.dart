import 'study_models.dart';

class MemoryUpdate {
  const MemoryUpdate({
    required this.card,
    required this.log,
    required this.dueAt,
    required this.modelVersion,
  });
  final Map<String, dynamic> card, log;
  final DateTime dueAt;
  final String modelVersion;
}

abstract interface class ReviewScheduler {
  String get version;
  bool isValidStoredCard(Map<String, dynamic> card);
  double retrievability(Map<String, dynamic> card, DateTime at);
  MemoryUpdate review(
    Map<String, dynamic>? previous,
    RecallGrade grade,
    DateTime at, {
    required int cardId,
  });
}
