part of 'sqlite_study_repository.dart';

Future<CommitReceipt> _recordAttempt(
  SqliteStudyRepository repo,
  String commandId,
  AttemptEvidence evidence,
) async {
  repo._word(evidence.wordId);
  if (evidence.attemptId.isEmpty ||
      evidence.hinted && evidence.independent ||
      !{
        'user_self_report',
        'objective_text',
        'objective_listening',
        'reading_supplement',
        'exposure',
        'practice_completed',
      }.contains(evidence.source)) {
    throw const StudyFailure('INVALID_ARGUMENT', '练习证据不符合当前模式。');
  }
  if ({
        'exposure',
        'reading_supplement',
        'practice_completed',
      }.contains(evidence.source) &&
      evidence.independent) {
    throw const StudyFailure('INVALID_ARGUMENT', '浏览、文本补练与自练不能作为独立正确证据。');
  }
  if (evidence.skill == StudySkill.pronunciation &&
      evidence.source != 'practice_completed') {
    throw const StudyFailure('CAPABILITY_UNAVAILABLE', '发音尚未自动评测，只能记录自练完成。');
  }
  if (evidence.source == 'objective_text' &&
      evidence.correct !=
          (evidence.answer.trim().toLowerCase() ==
              repo.catalog.words[evidence.wordId]?.word.toLowerCase())) {
    throw const StudyFailure('INVALID_ARGUMENT', '拼写结果与实际答案不一致。');
  }
  return repo._command(commandId, {'type': 'attempt', ...evidence.toJson()}, (
    tx,
    op,
  ) async {
    if ((await tx.query(
      'exams',
      where: 'status=?',
      whereArgs: ['active'],
      limit: 1,
    )).isNotEmpty) {
      throw const StudyFailure('MODE_FORBIDDEN', '考试中不能提交日常练习证据。');
    }
    final before = await tx.query(
      'attempts',
      where: 'id=?',
      whereArgs: [evidence.attemptId],
    );
    if (before.isNotEmpty) {
      if (before.single['payload'] != jsonEncode(evidence.toJson())) {
        throw const StudyFailure('VERSION_CONFLICT', '首次作答已经提交，不能覆盖。');
      }
      return {'attempt_id': evidence.attemptId, 'message': '这次练习此前已保存。'};
    }
    final at = repo.clock().toUtc();
    await repo._ensureWord(tx, evidence.wordId);
    await tx.update(
      'word_state',
      {'selected': 1},
      where: 'word_id=?',
      whereArgs: [evidence.wordId],
    );
    await tx.insert('attempts', {
      'id': evidence.attemptId,
      'word_id': evidence.wordId,
      'skill': evidence.skill.name,
      'payload': jsonEncode(evidence.toJson()),
      'created_at': at.toIso8601String(),
    });
    if (evidence.source != 'exposure') {
      await tx.update(
        'word_state',
        {'introduced': 1},
        where: 'word_id=?',
        whereArgs: [evidence.wordId],
      );
    }
    final graded = evidence.successfulIndependent
        ? evidence.grade
        : RecallGrade.again;
    final activeReview = evidence.reviewPointId == null
        ? <Map<String, Object?>>[]
        : await tx.query(
            'review_points',
            where: 'id=?',
            whereArgs: [evidence.reviewPointId],
          );
    if (activeReview.isNotEmpty &&
        (activeReview.single['word_id'] != evidence.wordId ||
            activeReview.single['skill'] != evidence.skill.name)) {
      throw const StudyFailure('INVALID_ARGUMENT', '练习技能与复习任务不一致。');
    }
    if (activeReview.isNotEmpty &&
        (evidence.successfulIndependent ||
            evidence.source == 'practice_completed')) {
      await tx.update(
        'review_points',
        {
          'status': 'done',
          'completed_at': at.toIso8601String(),
          'revision': (activeReview.single['revision'] as int) + 1,
        },
        where: 'id=?',
        whereArgs: [evidence.reviewPointId],
      );
    }
    if (evidence.skill != StudySkill.pronunciation &&
        evidence.source != 'exposure' &&
        evidence.source != 'reading_supplement') {
      await tx.insert('memory_states', {
        'word_id': evidence.wordId,
        'skill': evidence.skill.name,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      final memory = (await tx.query(
        'memory_states',
        where: 'word_id=? AND skill=?',
        whereArgs: [evidence.wordId, evidence.skill.name],
      )).single;
      final update = repo.scheduler.review(
        memory['card'] == null ? null : repo._decode(memory['card']),
        graded,
        at,
        cardId: memory['card_id'] as int,
      );
      await tx.update(
        'memory_states',
        {
          'card': jsonEncode(update.card),
          'log': jsonEncode(update.log),
          'model_version': update.modelVersion,
          'evidence_cursor': evidence.attemptId,
        },
        where: 'card_id=?',
        whereArgs: [memory['card_id']],
      );
      final existing = await tx.query(
        'review_points',
        where: 'word_id=? AND skill=? AND status IN (?,?)',
        whereArgs: [evidence.wordId, evidence.skill.name, 'planned', 'pending'],
      );
      DateTime? actualDue;
      if (existing.isEmpty) {
        actualDue = update.dueAt;
        await tx.insert('review_points', {
          'id': repo._id('rp'),
          'word_id': evidence.wordId,
          'skill': evidence.skill.name,
          'status': 'planned',
          'due_at': update.dueAt.toUtc().toIso8601String(),
          'revision': 1,
          'base_owned': 1,
        });
      } else {
        await tx.update(
          'review_points',
          {'base_owned': 1},
          where: 'id=?',
          whereArgs: [existing.first['id']],
        );
        if (existing.first['status'] == 'planned') {
          final constraints = await tx.query(
            'contributions',
            where: 'point_id=? AND active=1',
            whereArgs: [existing.first['id']],
          );
          var due = update.dueAt;
          for (final constraint in constraints) {
            final raw = constraint['requested_due'] as String?;
            if (raw == null) continue;
            final requested = DateTime.parse(raw);
            if (requested.isAfter(at) && requested.isBefore(due)) {
              due = requested;
            }
          }
          actualDue = due;
          await tx.update(
            'review_points',
            {
              'due_at': due.toUtc().toIso8601String(),
              'revision': (existing.first['revision'] as int) + 1,
            },
            where: 'id=?',
            whereArgs: [existing.first['id']],
          );
        }
      }
      final scheduleStatus =
          existing.isNotEmpty && existing.first['status'] == 'pending'
          ? 'pending'
          : 'planned';
      return {
        'attempt_id': evidence.attemptId,
        'memory_model': update.modelVersion,
        if (actualDue != null)
          'next_due_at': actualDue.toUtc().toIso8601String(),
        if (actualDue == null)
          'suggested_due_at': update.dueAt.toUtc().toIso8601String(),
        'rating': graded.name,
        'schedule_status': scheduleStatus,
        'message': scheduleStatus == 'pending'
            ? '证据已保存，复习点时间尚未安排。'
            : '本次证据已保存，后续复习已按FSRS-6安排。',
      };
    }
    return {
      'attempt_id': evidence.attemptId,
      'assessment_status': 'not_assessed',
      'assessment_reason': 'provider_disabled',
      'message': evidence.skill == StudySkill.pronunciation
          ? '跟读自练已保存；发音未自动评测。'
          : '本次阅读或接触记录已保存，未当作独立听辨。',
    };
  });
}
