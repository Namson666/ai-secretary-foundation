part of 'sqlite_study_repository.dart';

Future<CommitReceipt> _addReview(
  SqliteStudyRepository repo,
  String commandId,
  String wordId,
  StudySkill skill,
  String source,
  DateTime? requestedDue,
) {
  repo._word(wordId);
  if (source.isEmpty) throw const StudyFailure('INVALID_ARGUMENT', '缺少收录来源。');
  return repo._command(
    commandId,
    {
      'type': 'review_add',
      'wordId': wordId,
      'skill': skill.name,
      'source': source,
      'requestedDue': requestedDue?.toUtc().toIso8601String(),
    },
    (tx, op) async {
      await repo._ensureWord(tx, wordId);
      await tx.update(
        'word_state',
        {'selected': 1},
        where: 'word_id=?',
        whereArgs: [wordId],
      );
      final existing = await tx.query(
        'review_points',
        where: 'word_id=? AND skill=? AND status IN (?,?)',
        whereArgs: [wordId, skill.name, 'pending', 'planned'],
      );
      final pointId = existing.isEmpty
          ? repo._id('rp')
          : existing.first['id'] as String;
      if (existing.isEmpty) {
        await tx.insert('review_points', {
          'id': pointId,
          'word_id': wordId,
          'skill': skill.name,
          'status': 'pending',
          'revision': 1,
        });
      } else {
        await tx.update(
          'review_points',
          {'revision': (existing.first['revision'] as int) + 1},
          where: 'id=?',
          whereArgs: [pointId],
        );
      }
      await tx.insert('contributions', {
        'operation_id': op,
        'point_id': pointId,
        'active': 1,
        'source': source,
        'requested_due': requestedDue?.toUtc().toIso8601String(),
      });
      final status = existing.isNotEmpty ? existing.first['status'] : 'pending';
      return {
        'point_id': pointId,
        'word_id': wordId,
        'skill': skill.name,
        'schedule_status': status,
        'assessment_status': 'not_assessed',
        'undoable': true,
        'message': status == 'planned' ? '复习点已保存，已有安排保持。' : '复习点已保存，时间尚未安排。',
      };
    },
  );
}

Future<CommitReceipt> _schedule(
  SqliteStudyRepository repo,
  String commandId,
  String pointId,
  DateTime dueAt,
  int expectedRevision,
) => repo._command(
  commandId,
  {
    'type': 'schedule',
    'pointId': pointId,
    'dueAt': dueAt.toUtc().toIso8601String(),
    'expectedRevision': expectedRevision,
  },
  (tx, op) async {
    final rows = await tx.query(
      'review_points',
      where: 'id=?',
      whereArgs: [pointId],
    );
    if (rows.isEmpty) throw const StudyFailure('INVALID_ARGUMENT', '复习点不存在。');
    final point = rows.single;
    if (point['revision'] != expectedRevision || point['status'] == 'done') {
      throw const StudyFailure('VERSION_CONFLICT', '复习点已有更新，请刷新。');
    }
    if (dueAt.toUtc().isBefore(repo.clock().toUtc())) {
      throw const StudyFailure('INVALID_ARGUMENT', '安排时间不能早于现在。');
    }
    final preferences = StudyPreferences.fromJson(
      repo._decode((await tx.query('preferences')).single['data']),
    );
    final day = StudyService.chinaDay(dueAt);
    final count =
        Sqflite.firstIntValue(
          await tx.rawQuery(
            'SELECT count(*) FROM review_points WHERE status=? AND due_at>=? AND due_at<? AND id<>?',
            [
              'planned',
              day.toIso8601String(),
              day.add(const Duration(days: 1)).toIso8601String(),
              pointId,
            ],
          ),
        ) ??
        0;
    if (count >= preferences.dailyLimit ||
        (count + 1) * 3 > preferences.budgetMinutes) {
      throw const StudyFailure('BUDGET_EXCEEDED', '这一天的复习已达到预算，请换时间或调整计划。');
    }
    await tx.update(
      'review_points',
      {
        'status': 'planned',
        'due_at': dueAt.toUtc().toIso8601String(),
        'revision': expectedRevision + 1,
      },
      where: 'id=?',
      whereArgs: [pointId],
    );
    return {
      'point_id': pointId,
      'schedule_status': 'planned',
      'due_at': dueAt.toUtc().toIso8601String(),
      'revision': expectedRevision + 1,
      'message': '已安排复习，具体时间已保存。',
    };
  },
);
Future<CommitReceipt> _undo(
  SqliteStudyRepository repo,
  String commandId,
  String operationId,
) => repo._command(commandId, {'type': 'undo', 'operationId': operationId}, (
  tx,
  op,
) async {
  final contributions = await tx.query(
    'contributions',
    where: 'operation_id=?',
    whereArgs: [operationId],
  );
  if (contributions.isEmpty) {
    throw const StudyFailure('INVALID_ARGUMENT', '找不到可撤销的收录贡献。');
  }
  final contribution = contributions.single;
  if (contribution['active'] == 0) {
    return {
      'reverted_operation_id': operationId,
      'already_reverted': true,
      'undo_scope': 'this_contribution_only',
      'message': '本次贡献此前已撤销。',
    };
  }
  await tx.update(
    'contributions',
    {'active': 0},
    where: 'operation_id=?',
    whereArgs: [operationId],
  );
  final remaining = await tx.query(
    'contributions',
    where: 'point_id=? AND active=1',
    whereArgs: [contribution['point_id']],
  );
  final points = await tx.query(
    'review_points',
    where: 'id=?',
    whereArgs: [contribution['point_id']],
  );
  if (remaining.isEmpty &&
      points.single['status'] != 'done' &&
      points.single['base_owned'] == 0) {
    await tx.update(
      'review_points',
      {
        'status': 'cancelled',
        'revision': (points.single['revision'] as int) + 1,
      },
      where: 'id=?',
      whereArgs: [contribution['point_id']],
    );
  }
  if (points.single['status'] != 'done' && points.single['base_owned'] == 1) {
    final memory = await tx.query(
      'memory_states',
      where: 'word_id=? AND skill=?',
      whereArgs: [points.single['word_id'], points.single['skill']],
    );
    if (memory.isNotEmpty && memory.single['card'] != null) {
      var due = DateTime.parse(
        repo._decode(memory.single['card'])['due'] as String,
      );
      for (final c in remaining) {
        final raw = c['requested_due'] as String?;
        if (raw != null) {
          final requested = DateTime.parse(raw);
          if (requested.isAfter(repo.clock()) && requested.isBefore(due)) {
            due = requested;
          }
        }
      }
      await tx.update(
        'review_points',
        {
          'status': 'planned',
          'due_at': due.toUtc().toIso8601String(),
          'revision': (points.single['revision'] as int) + 1,
        },
        where: 'id=?',
        whereArgs: [contribution['point_id']],
      );
    }
  }
  return {
    'point_id': contribution['point_id'],
    'reverted_operation_id': operationId,
    'undo_scope': 'this_contribution_only',
    'message': '已撤销本次贡献，其他收录与练习历史保留。',
  };
});
