part of 'sqlite_study_repository.dart';

Future<CommitReceipt> _startExam(
  SqliteStudyRepository repo,
  String id,
  Map<String, dynamic> config,
) => repo._command(id, {'type': 'exam_start', 'config': config}, (
  tx,
  op,
) async {
  final items = config['items'];
  if (items is! List ||
      items.isEmpty ||
      items.length > 100 ||
      config['pronunciationScoring'] != 'disabled') {
    throw const StudyFailure('CAPABILITY_UNAVAILABLE', '当前试卷仅支持明确配置的非发音评分题。');
  }
  for (final raw in items) {
    if (raw is! Map ||
        raw['id'] is! String ||
        raw['prompt'] is! String ||
        raw['answer'] is! String) {
      throw const StudyFailure('INVALID_ARGUMENT', '题目配置不完整。');
    }
  }
  final exam = repo._id('exam');
  await tx.insert('exams', {
    'id': exam,
    'config': jsonEncode(config),
    'answers': '{}',
    'status': 'active',
    'started_at': repo.clock().toUtc().toIso8601String(),
  });
  return {'exam_id': exam, 'message': '考试已开始，题目与评分规则已冻结。'};
});
Future<CommitReceipt> _submitExam(
  SqliteStudyRepository repo,
  String id,
  String examId,
  Map<String, String> answers,
) => repo._command(
  id,
  {'type': 'exam_submit', 'examId': examId, 'answers': answers},
  (tx, op) async {
    final rows = await tx.query('exams', where: 'id=?', whereArgs: [examId]);
    if (rows.isEmpty || rows.single['status'] != 'active') {
      throw const StudyFailure('MODE_FORBIDDEN', '考试当前不能交卷。');
    }
    final config = repo._decode(rows.single['config']);
    final items = config['items'] as List;
    if (items.any(
      (raw) => !(answers[(raw as Map)['id']]?.trim().isNotEmpty ?? false),
    )) {
      throw const StudyFailure('INVALID_ARGUMENT', '请完成全部题目后交卷。');
    }
    await tx.update(
      'exams',
      {'answers': jsonEncode(answers), 'status': 'submitted'},
      where: 'id=?',
      whereArgs: [examId],
    );
    return {'exam_id': examId, 'message': '试卷已封存，等待评分。'};
  },
);
Future<CommitReceipt> _gradeExam(
  SqliteStudyRepository repo,
  String id,
  String examId,
) =>
    repo._command(id, {'type': 'exam_grade', 'examId': examId}, (tx, op) async {
      final rows = await tx.query('exams', where: 'id=?', whereArgs: [examId]);
      if (rows.isEmpty || rows.single['status'] != 'submitted') {
        throw const StudyFailure('MODE_FORBIDDEN', '该场考试尚未提交。');
      }
      final config = repo._decode(rows.single['config']);
      final answers = repo._decode(rows.single['answers']);
      final results = <Map<String, dynamic>>[];
      for (final raw in config['items'] as List) {
        final item = Map<String, dynamic>.from(raw as Map);
        final submitted = answers[item['id']] as String;
        final correct =
            submitted.trim().toLowerCase() ==
            (item['answer'] as String).trim().toLowerCase();
        results.add({
          'id': item['id'],
          'correct': correct,
          'answer': submitted,
          'reference': item['answer'],
          'explanation': item['explanation'] ?? '',
        });
      }
      await tx.update(
        'exams',
        {
          'status': 'graded',
          'grade': jsonEncode({
            'score': results.where((r) => r['correct'] == true).length,
            'total': results.length,
            'results': results,
            'gradingVersion': 'exact-match-v1',
            'pronunciationStatus': 'not_assessed',
          }),
        },
        where: 'id=?',
        whereArgs: [examId],
      );
      return {'exam_id': examId, 'message': '评分已完成，结果尚未发布。'};
    });
Future<CommitReceipt> _publishExam(
  SqliteStudyRepository repo,
  String id,
  String examId,
) => repo._command(id, {'type': 'exam_publish', 'examId': examId}, (
  tx,
  op,
) async {
  final rows = await tx.query('exams', where: 'id=?', whereArgs: [examId]);
  if (rows.isEmpty || rows.single['status'] != 'graded') {
    throw const StudyFailure('MODE_FORBIDDEN', '成绩尚不能发布。');
  }
  await tx.update(
    'exams',
    {'status': 'published'},
    where: 'id=?',
    whereArgs: [examId],
  );
  return {'exam_id': examId, 'message': '成绩已发布，测量范围为本场配置的题型。'};
});
