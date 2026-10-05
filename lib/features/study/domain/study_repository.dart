import 'study_models.dart';
import 'study_analytics.dart';

abstract interface class StudyRepository {
  Future<StudySnapshot> load();
  Future<StudyAnalytics> getAnalytics();
  Future<T> withCommandLease<T>(
    bool Function() isCurrent,
    Future<T> Function() action,
  );
  Future<CommitReceipt> selectWords(String commandId, List<String> ids);
  Future<CommitReceipt> updateWord(
    String commandId,
    String id, {
    WordDisposition? disposition,
    bool? favorite,
    String? note,
  });
  Future<CommitReceipt> proposePlan(
    String commandId,
    Map<String, dynamic> changes,
  );
  Future<CommitReceipt> activatePlan(String commandId, String proposalId);
  Future<CommitReceipt> updatePreferences(
    String commandId,
    Map<String, dynamic> changes, {
    required int expectedRevision,
  });
  Future<CommitReceipt> recordAttempt(
    String commandId,
    AttemptEvidence evidence,
  );
  Future<CommitReceipt> addReview(
    String commandId,
    String wordId,
    StudySkill skill, {
    required String source,
    DateTime? requestedDue,
  });
  Future<CommitReceipt> schedule(
    String commandId,
    String pointId,
    DateTime dueAt, {
    required int expectedRevision,
  });
  Future<CommitReceipt> undo(String commandId, String operationId);
  Future<CommitReceipt?> receipt(String commandId);
  Future<CommitReceipt> controlSession(
    String commandId,
    String action, {
    Map<String, dynamic>? session,
  });
  Future<CommitReceipt> endSession(String commandId);
  Future<void> saveSession(Map<String, dynamic>? session);
  Future<Map<String, dynamic>> exportBackup();
  Future<void> restoreBackup(Map<String, dynamic> backup);
  Future<CommitReceipt> startExam(
    String commandId,
    Map<String, dynamic> config,
  );
  Future<void> saveExamDraft(String examId, Map<String, String> answers);
  Future<CommitReceipt> submitExam(
    String commandId,
    String examId,
    Map<String, String> answers,
  );
  Future<CommitReceipt> gradeExam(String commandId, String examId);
  Future<CommitReceipt> publishExam(String commandId, String examId);
  Future<void> close();
}
