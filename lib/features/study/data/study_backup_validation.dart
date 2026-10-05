part of 'sqlite_study_repository.dart';

Future<void> _validateStudyBackup(
  SqliteStudyRepository repo,
  Map<String, dynamic> values,
) async {
  Never invalid() =>
      throw const StudyFailure('INVALID_ARGUMENT', '备份包含无效字段、状态或引用；原记录未修改。');
  Map<String, dynamic> object(Object? raw) {
    if (raw is! Map) invalid();
    return Map<String, dynamic>.from(raw);
  }

  Map<String, dynamic> parsed(Object? raw) {
    if (raw is! String) invalid();
    try {
      return object(jsonDecode(raw));
    } catch (_) {
      invalid();
    }
  }

  bool text(Object? raw) =>
      raw is String && raw.isNotEmpty && raw.length <= 200000;
  bool integer(Object? raw) => raw is int && raw >= 0;
  bool timestamp(Object? raw) {
    if (raw is! String) return false;
    final d = DateTime.tryParse(raw);
    return d != null && d.isUtc;
  }

  final rows = <String, List<Map<String, dynamic>>>{};
  for (final table in SqliteStudyRepository.tables) {
    final raw = values[table];
    if (raw is! List || raw.length > 100000) invalid();
    final columns = await repo.database.rawQuery('PRAGMA table_info($table)');
    final names = columns.map((c) => c['name'] as String).toSet();
    rows[table] = (raw).map(object).toList();
    for (final row in rows[table]!) {
      if (row.keys.toSet().difference(names).isNotEmpty ||
          names.difference(row.keys.toSet()).isNotEmpty) {
        invalid();
      }
      for (final column in columns) {
        final value = row[column['name']];
        if (value == null) {
          if (column['notnull'] == 1) invalid();
          continue;
        }
        if (column['type'] == 'INTEGER' && value is! int ||
            column['type'] == 'TEXT' && value is! String) {
          invalid();
        }
      }
      if (row['word_id'] != null &&
          !repo.catalog.words.containsKey(row['word_id'])) {
        invalid();
      }
    }
  }
  final preferences = rows['preferences']!;
  if (preferences.length != 1 || preferences.single['id'] != 1) invalid();
  final prefs = parsed(preferences.single['data']);
  if (!repo.catalog.books.any((b) => b.id == prefs['bookId']) ||
      ![10, 20, 30, 50, 80].contains(prefs['dailyLimit']) ||
      ![0, 5, 10, 20, 30].contains(prefs['newLimit']) ||
      ![10, 20, 30, 45].contains(prefs['budgetMinutes']) ||
      !['en-cn', 'cn-en', 'spell', 'listen'].contains(prefs['direction']) ||
      !['book', 'random', 'review'].contains(prefs['order']) ||
      !['manual', 'assisted', 'managed'].contains(prefs['mode']) ||
      prefs['timezone'] != 'Asia/Shanghai' ||
      prefs['quiet'] is! bool ||
      prefs['goal'] is! String ||
      !integer(prefs['revision'])) {
    invalid();
  }
  final skills = StudySkill.values.map((s) => s.name).toSet(),
      grades = RecallGrade.values.map((g) => g.name).toSet();
  for (final row in rows['word_state']!) {
    if (![0, 1].contains(row['selected']) ||
        ![0, 1].contains(row['introduced']) ||
        ![0, 1].contains(row['favorite']) ||
        !WordDisposition.values.any((s) => s.name == row['disposition']) ||
        (row['note'] as String).length > 2000) {
      invalid();
    }
  }
  final attemptIds = <String>{};
  for (final row in rows['attempts']!) {
    if (!text(row['id']) ||
        !attemptIds.add(row['id'] as String) ||
        !skills.contains(row['skill']) ||
        !timestamp(row['created_at'])) {
      invalid();
    }
    final e = parsed(row['payload']);
    if (e['attemptId'] != row['id'] ||
        e['wordId'] != row['word_id'] ||
        e['skill'] != row['skill'] ||
        !grades.contains(e['grade']) ||
        e['independent'] is! bool ||
        e['hinted'] is! bool ||
        e['answer'] is! String ||
        e['correct'] != null && e['correct'] is! bool ||
        !{
          'user_self_report',
          'objective_text',
          'objective_listening',
          'reading_supplement',
          'exposure',
          'practice_completed',
        }.contains(e['source']) ||
        e['independent'] == true &&
            (e['hinted'] == true ||
                {
                  'exposure',
                  'reading_supplement',
                  'practice_completed',
                }.contains(e['source']))) {
      invalid();
    }
  }
  final pointIds = <String>{};
  for (final row in rows['review_points']!) {
    if (!text(row['id']) ||
        !pointIds.add(row['id'] as String) ||
        !skills.contains(row['skill']) ||
        !{'pending', 'planned', 'done', 'cancelled'}.contains(row['status']) ||
        !integer(row['revision']) ||
        ![0, 1].contains(row['base_owned']) ||
        row['due_at'] != null && !timestamp(row['due_at']) ||
        row['status'] == 'planned' && row['due_at'] == null ||
        row['completed_at'] != null && !timestamp(row['completed_at'])) {
      invalid();
    }
  }
  for (final row in rows['memory_states']!) {
    if (!integer(row['card_id']) ||
        !skills.contains(row['skill']) ||
        row['skill'] == 'pronunciation' ||
        row['model_version'] != repo.scheduler.version ||
        !attemptIds.contains(row['evidence_cursor'])) {
      invalid();
    }
    final evidence = rows['attempts']!.firstWhere(
      (a) => a['id'] == row['evidence_cursor'],
    );
    if (evidence['word_id'] != row['word_id'] ||
        evidence['skill'] != row['skill']) {
      invalid();
    }
    final card = parsed(row['card']);
    final log = parsed(row['log']);
    if (card['cardId'] != row['card_id'] ||
        !repo.scheduler.isValidStoredCard(card) ||
        ![1, 2, 3].contains(card['state']) ||
        card['stability'] is! num ||
        card['difficulty'] is! num ||
        (card['stability'] as num) <= 0 ||
        (card['difficulty'] as num) < 1 ||
        (card['difficulty'] as num) > 10 ||
        !timestamp(card['due']) ||
        !timestamp(card['lastReview']) ||
        log['desiredRetention'] is! num ||
        (log['desiredRetention'] as num) <= 0 ||
        (log['desiredRetention'] as num) >= 1 ||
        log['parameterVersion'] != 'default-21-v2.0.1' ||
        log['parameters'] is! List ||
        (log['parameters'] as List).length != 21 ||
        (log['parameters'] as List).any((p) => p is! num) ||
        ![1, 2, 3, 4].contains(log['rating'])) {
      invalid();
    }
  }
  final operations = <String>{};
  for (final row in rows['commands']!) {
    if (!text(row['command_id'])) invalid();
    parsed(row['payload']);
    final receipt = parsed(row['receipt']);
    if (receipt['status'] != 'committed' ||
        receipt['commit_state'] != 'committed' ||
        receipt['command_id'] != row['command_id'] ||
        receipt['sync_status'] != 'local_only' ||
        !text(receipt['operation_id']) ||
        !operations.add(receipt['operation_id'] as String)) {
      invalid();
    }
  }
  for (final row in rows['contributions']!) {
    if (!operations.contains(row['operation_id']) ||
        !pointIds.contains(row['point_id']) ||
        ![0, 1].contains(row['active']) ||
        !text(row['source']) ||
        row['requested_due'] != null && !timestamp(row['requested_due'])) {
      invalid();
    }
  }
  for (final row in rows['outbox']!) {
    if (!operations.contains(row['event_id']) ||
        row['status'] != 'local' ||
        !timestamp(row['created_at'])) {
      invalid();
    }
    parsed(row['payload']);
  }
  for (final row in rows['checkpoints']!) {
    if (row['id'] != 1) invalid();
    final checkpoint = parsed(row['payload']);
    final tasks = checkpoint['tasks'];
    if (tasks is! List || tasks.isEmpty || tasks.length > 80) invalid();
    for (final item in tasks) {
      final task = object(item);
      if (!repo.catalog.words.containsKey(task['wordId']) ||
          !skills.contains(task['skill'])) {
        invalid();
      }
    }
    for (final key in [
      'revealed',
      'hinted',
      'claimed',
      'submitted',
      'reading',
    ]) {
      if (checkpoint[key] != null && checkpoint[key] is! bool) invalid();
    }
    for (final key in ['answer', 'feedback', 'attemptId']) {
      if (checkpoint[key] != null && checkpoint[key] is! String) invalid();
    }
    if (checkpoint['hinted'] == true &&
        checkpoint['claimed'] == true &&
        checkpoint['revealed'] != true) {
      invalid();
    }
    if (checkpoint['index'] is! int ||
        (checkpoint['index'] as int) < 0 ||
        (checkpoint['index'] as int) >= tasks.length) {
      invalid();
    }
    if (checkpoint['frozenEvidence'] != null) {
      final e = object(checkpoint['frozenEvidence']);
      final current = object(tasks[checkpoint['index'] as int]);
      if (e['attemptId'] != checkpoint['attemptId'] ||
          e['wordId'] != current['wordId'] ||
          e['skill'] != current['skill'] ||
          !grades.contains(e['grade']) ||
          e['independent'] is! bool ||
          e['hinted'] is! bool ||
          e['answer'] is! String ||
          e['correct'] != null && e['correct'] is! bool ||
          !{
            'user_self_report',
            'objective_text',
            'objective_listening',
            'reading_supplement',
            'exposure',
            'practice_completed',
          }.contains(e['source']) ||
          e['independent'] == true &&
              (e['hinted'] == true ||
                  {
                    'reading_supplement',
                    'exposure',
                    'practice_completed',
                  }.contains(e['source']))) {
        invalid();
      }
    }
  }
  for (final row in rows['proposals']!) {
    if (!text(row['id']) ||
        !integer(row['expected_revision']) ||
        !{'pending', 'activated'}.contains(row['status']) ||
        !timestamp(row['expires_at'])) {
      invalid();
    }
    final payload = parsed(row['payload']);
    if (payload.keys.any(
      (k) => !{'newLimit', 'dailyLimit', 'budgetMinutes', 'mode'}.contains(k),
    )) {
      invalid();
    }
  }
  for (final row in rows['exams']!) {
    if (!text(row['id']) ||
        !{
          'active',
          'submitted',
          'graded',
          'published',
        }.contains(row['status']) ||
        !timestamp(row['started_at'])) {
      invalid();
    }
    final config = parsed(row['config']);
    final answers = parsed(row['answers']);
    if (config['pronunciationScoring'] != 'disabled' ||
        config['items'] is! List ||
        (config['items'] as List).isEmpty) {
      invalid();
    }
    final questionIds = <String>{};
    for (final raw in config['items'] as List) {
      final item = object(raw);
      if (!text(item['id']) ||
          !questionIds.add(item['id'] as String) ||
          !text(item['prompt']) ||
          !text(item['answer'])) {
        invalid();
      }
    }
    if (answers.keys.any((id) => !questionIds.contains(id)) ||
        answers.values.any((a) => a is! String)) {
      invalid();
    }
    if ({'graded', 'published'}.contains(row['status'])) {
      final grade = parsed(row['grade']);
      if (!integer(grade['score']) ||
          grade['total'] != questionIds.length ||
          grade['results'] is! List ||
          (grade['results'] as List).length != questionIds.length ||
          grade['gradingVersion'] != 'exact-match-v1' ||
          grade['pronunciationStatus'] != 'not_assessed') {
        invalid();
      }
      final resultIds = <String>{};
      var score = 0;
      for (final raw in grade['results'] as List) {
        final result = object(raw);
        if (!questionIds.contains(result['id']) ||
            !resultIds.add(result['id'] as String) ||
            result['correct'] is! bool ||
            result['answer'] is! String ||
            result['reference'] is! String ||
            result['explanation'] is! String) {
          invalid();
        }
        final question = (config['items'] as List)
            .map(object)
            .firstWhere((q) => q['id'] == result['id']);
        final matches =
            (result['answer'] as String).trim().toLowerCase() ==
            (question['answer'] as String).trim().toLowerCase();
        if (result['reference'] != question['answer'] ||
            result['answer'] != answers[result['id']] ||
            result['correct'] != matches) {
          invalid();
        }
        if (matches) score++;
      }
      if (grade['score'] != score) invalid();
    }
  }
}
