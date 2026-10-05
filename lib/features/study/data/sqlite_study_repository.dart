import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:path/path.dart' as paths;
import 'package:sqflite/sqflite.dart';
import '../domain/study_models.dart';
import '../domain/study_analytics.dart';
import '../domain/study_repository.dart';
import '../domain/review_scheduler.dart';
import '../domain/study_service.dart';
part 'study_attempt_storage.dart';
part 'study_review_storage.dart';
part 'study_exam_storage.dart';
part 'study_backup_validation.dart';

class SqliteStudyRepository implements StudyRepository {
  SqliteStudyRepository._(
    this.database,
    this.catalog,
    this.scheduler,
    this.clock,
  );
  final Database database;
  final StudyCatalog catalog;
  final ReviewScheduler scheduler;
  final DateTime Function() clock;
  static const tables = [
    'preferences',
    'word_state',
    'attempts',
    'memory_states',
    'review_points',
    'contributions',
    'commands',
    'outbox',
    'checkpoints',
    'exams',
    'proposals',
  ];
  static Future<SqliteStudyRepository> open(
    StudyCatalog catalog,
    ReviewScheduler scheduler, {
    DatabaseFactory? factory,
    String? databasePath,
    DateTime Function()? clock,
  }) async {
    final backend = factory ?? databaseFactory;
    final path =
        databasePath ??
        paths.join(await backend.getDatabasesPath(), 'study.sqlite');
    final db = await backend.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys=ON');
        },
        onCreate: (db, version) async {
          for (final sql in _schema) {
            await db.execute(sql);
          }
          await db.insert('preferences', {
            'id': 1,
            'data': jsonEncode(const StudyPreferences().toJson()),
          });
          final first = catalog.books.first.wordIds.take(20).toSet()
            ..addAll(['ship', 'journey', 'transfer', 'resilient']);
          for (final id in first.where(catalog.words.containsKey)) {
            await db.insert('word_state', {
              'word_id': id,
              'selected': 1,
              'disposition': 'active',
              'favorite': 0,
              'note': '',
              'introduced': 0,
            });
          }
        },
      ),
    );
    return SqliteStudyRepository._(
      db,
      catalog,
      scheduler,
      clock ?? DateTime.now,
    );
  }

  static const _schema = [
    'CREATE TABLE preferences(id INTEGER PRIMARY KEY CHECK(id=1),data TEXT NOT NULL)',
    'CREATE TABLE word_state(word_id TEXT PRIMARY KEY,selected INTEGER NOT NULL,disposition TEXT NOT NULL,favorite INTEGER NOT NULL,note TEXT NOT NULL,introduced INTEGER NOT NULL)',
    'CREATE TABLE attempts(id TEXT PRIMARY KEY,word_id TEXT NOT NULL,skill TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL)',
    'CREATE TABLE memory_states(card_id INTEGER PRIMARY KEY AUTOINCREMENT,word_id TEXT NOT NULL,skill TEXT NOT NULL,card TEXT,log TEXT,model_version TEXT,evidence_cursor TEXT,UNIQUE(word_id,skill))',
    'CREATE TABLE review_points(id TEXT PRIMARY KEY,word_id TEXT NOT NULL,skill TEXT NOT NULL,status TEXT NOT NULL,due_at TEXT,revision INTEGER NOT NULL,completed_at TEXT,base_owned INTEGER NOT NULL DEFAULT 0)',
    'CREATE TABLE contributions(operation_id TEXT PRIMARY KEY,point_id TEXT NOT NULL REFERENCES review_points(id),active INTEGER NOT NULL,source TEXT NOT NULL,requested_due TEXT)',
    'CREATE TABLE commands(command_id TEXT PRIMARY KEY,payload TEXT NOT NULL,receipt TEXT NOT NULL)',
    'CREATE TABLE outbox(event_id TEXT PRIMARY KEY,event_type TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL,status TEXT NOT NULL)',
    'CREATE TABLE checkpoints(id INTEGER PRIMARY KEY CHECK(id=1),payload TEXT NOT NULL)',
    'CREATE TABLE exams(id TEXT PRIMARY KEY,config TEXT NOT NULL,answers TEXT NOT NULL,status TEXT NOT NULL,grade TEXT,started_at TEXT NOT NULL)',
    'CREATE TABLE proposals(id TEXT PRIMARY KEY,payload TEXT NOT NULL,expected_revision INTEGER NOT NULL,status TEXT NOT NULL,expires_at TEXT NOT NULL)',
    'CREATE INDEX review_due ON review_points(status,due_at)',
    'CREATE INDEX attempt_time ON attempts(created_at)',
  ];
  String _id(String prefix) =>
      '${prefix}_${clock().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}';
  Object? _canonical(Object? raw) {
    if (raw is Map) {
      final keys = raw.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(raw[key])};
    }
    if (raw is List) return raw.map(_canonical).toList();
    return raw;
  }

  Map<String, dynamic> _decode(Object? value) =>
      Map<String, dynamic>.from(jsonDecode(value as String) as Map);
  Future<CommitReceipt> _command(
    String id,
    Map<String, dynamic> payload,
    Future<Map<String, dynamic>> Function(Transaction tx, String op) mutate,
  ) async {
    if (id.isEmpty || id.length > 200) {
      throw const StudyFailure('INVALID_ARGUMENT', '命令标识无效。');
    }
    final encoded = jsonEncode(_canonical(payload));
    return database.transaction((tx) async {
      _checkLease();
      final existing = await tx.query(
        'commands',
        where: 'command_id=?',
        whereArgs: [id],
      );
      if (existing.isNotEmpty) {
        if (existing.first['payload'] != encoded) {
          throw const StudyFailure('VERSION_CONFLICT', '同一命令标识不能用于不同内容。');
        }
        return CommitReceipt(_decode(existing.first['receipt']));
      }
      final op = _id('op');
      final result = {
        'status': 'committed',
        'commit_state': 'committed',
        'command_id': id,
        'operation_id': op,
        'sync_status': 'local_only',
        ...await mutate(tx, op),
      };
      await tx.insert('commands', {
        'command_id': id,
        'payload': encoded,
        'receipt': jsonEncode(result),
      });
      await tx.insert('outbox', {
        'event_id': op,
        'event_type': payload['type'],
        'payload': jsonEncode(result),
        'created_at': clock().toUtc().toIso8601String(),
        'status': 'local',
      });
      _checkLease();
      return CommitReceipt(Map.unmodifiable(result));
    });
  }

  @override
  Future<T> withCommandLease<T>(
    bool Function() isCurrent,
    Future<T> Function() action,
  ) => runZoned(action, zoneValues: {#studyCommandLease: isCurrent});
  void _checkLease() {
    final lease = Zone.current[#studyCommandLease] as bool Function()?;
    if (lease != null && !lease()) {
      throw const StudyFailure('CANCELLED', '本次指令已取消，未提交。');
    }
  }

  void _word(String id) {
    if (!catalog.words.containsKey(id)) {
      throw const StudyFailure('INVALID_ARGUMENT', '词条不存在。');
    }
  }

  Future<void> _ensureWord(DatabaseExecutor tx, String id) async {
    await tx.insert('word_state', {
      'word_id': id,
      'selected': 0,
      'disposition': 'active',
      'favorite': 0,
      'note': '',
      'introduced': 0,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Map<String, dynamic> _publicExamConfig(
    Map<String, dynamic> config,
    bool published,
  ) => {
    ...config,
    'items': (config['items'] as List).map((raw) {
      final item = Map<String, dynamic>.from(raw as Map);
      if (!published) {
        item.remove('answer');
        item.remove('explanation');
      }
      return item;
    }).toList(),
  };
  @override
  Future<StudyAnalytics> getAnalytics() async {
    final at = clock().toUtc();
    final skillRows = {
      for (final skill in StudySkill.values) skill: [0, 0, 0, 0],
    };
    final daily = <String, int>{};
    for (final row in await database.query('attempts')) {
      final e = _decode(row['payload']);
      final skill = StudySkill.values.byName(row['skill'] as String);
      if (e['source'] == 'exposure') continue;
      final counts = skillRows[skill]!;
      counts[0]++;
      if (e['independent'] == true &&
          e['hinted'] == false &&
          e['correct'] != false &&
          e['grade'] != 'again') {
        counts[1]++;
      }
      if (e['hinted'] == true) counts[2]++;
      if (e['grade'] == 'again' || e['correct'] == false) counts[3]++;
      final date = DateTime.parse(row['created_at'] as String)
          .toUtc()
          .add(const Duration(hours: 8))
          .toIso8601String()
          .substring(0, 10);
      daily[date] = (daily[date] ?? 0) + 1;
    }
    final memories = <MemoryStatistics>[];
    for (final row in await database.query('memory_states')) {
      if (row['card'] == null) continue;
      final card = _decode(row['card']);
      memories.add(
        MemoryStatistics(
          wordId: row['word_id'] as String,
          skill: StudySkill.values.byName(row['skill'] as String),
          stabilityDays: (card['stability'] as num).toDouble(),
          difficulty: (card['difficulty'] as num).toDouble(),
          dueAt: DateTime.parse(card['due'] as String),
          lastReview: DateTime.parse(card['lastReview'] as String),
          recallForecast: List.unmodifiable(
            StudyAnalytics.forecastDays.map(
              (d) => scheduler.retrievability(card, at.add(Duration(days: d))),
            ),
          ),
        ),
      );
    }
    return StudyAnalytics(
      capturedAt: at,
      bySkill: Map.unmodifiable(
        skillRows.map(
          (skill, c) => MapEntry(
            skill,
            SkillStatistics(
              attempts: c[0],
              independentSuccesses: c[1],
              hintedAttempts: c[2],
              forgottenAttempts: c[3],
            ),
          ),
        ),
      ),
      dailyAttempts: Map.unmodifiable(daily),
      memories: List.unmodifiable(memories),
    );
  }

  @override
  Future<StudySnapshot> load() async {
    final prefs = _decode((await database.query('preferences')).single['data']);
    final state = await database.query('word_state');
    final points = await database.query('review_points');
    final attempts = await database.query('attempts');
    final checkpoint = await database.query('checkpoints');
    final weeks = <String, int>{};
    int success = 0, today = 0;
    final introducedToday = <String>{};
    final firstSeen = <String, DateTime>{};
    final day = StudyService.chinaDay(clock());
    for (final row in attempts) {
      final observed = DateTime.parse(row['created_at'] as String);
      final word = row['word_id'] as String;
      final payload = _decode(row['payload']);
      if (payload['source'] != 'exposure' &&
          (!firstSeen.containsKey(word) ||
              observed.isBefore(firstSeen[word]!))) {
        firstSeen[word] = observed;
      }
      if (payload['independent'] == true &&
          payload['hinted'] == false &&
          payload['correct'] != false &&
          payload['grade'] != 'again') {
        success++;
      }
      final at = DateTime.parse(row['created_at'] as String);
      if (payload['source'] != 'exposure' &&
          !at.isBefore(day) &&
          at.isBefore(day.add(const Duration(days: 1)))) {
        today++;
      }
      final key = at
          .toUtc()
          .add(const Duration(hours: 8))
          .toIso8601String()
          .substring(0, 10);
      weeks[key] = (weeks[key] ?? 0) + 1;
    }
    for (final entry in firstSeen.entries) {
      if (!entry.value.isBefore(day) &&
          entry.value.isBefore(day.add(const Duration(days: 1)))) {
        introducedToday.add(entry.key);
      }
    }
    return StudySnapshot(
      preferences: StudyPreferences.fromJson(prefs),
      progress: {
        for (final row in state)
          row['word_id'] as String: WordProgress(
            wordId: row['word_id'] as String,
            selected: row['selected'] == 1,
            disposition: WordDisposition.values.byName(
              row['disposition'] as String,
            ),
            favorite: row['favorite'] == 1,
            note: row['note'] as String,
            introduced: row['introduced'] == 1,
          ),
      },
      reviews: points
          .map(
            (r) => ReviewPoint(
              id: r['id'] as String,
              wordId: r['word_id'] as String,
              skill: StudySkill.values.byName(r['skill'] as String),
              status: r['status'] as String,
              revision: r['revision'] as int,
              dueAt: r['due_at'] == null
                  ? null
                  : DateTime.parse(r['due_at'] as String),
            ),
          )
          .toList(),
      attemptCount: attempts.length,
      independentSuccessCount: success,
      todayAttempts: today,
      todayNewIntroductions: introducedToday.length,
      weekAttempts: weeks,
      session: checkpoint.isEmpty
          ? null
          : _decode(checkpoint.single['payload']),
      exams: (await database.query('exams', orderBy: 'started_at DESC'))
          .map(
            (r) => {
              'id': r['id'],
              'status': r['status'],
              'config': _publicExamConfig(
                _decode(r['config']),
                r['status'] == 'published',
              ),
              'answers': _decode(r['answers']),
              if (r['status'] == 'published') 'grade': _decode(r['grade']),
            },
          )
          .toList(),
    );
  }

  @override
  Future<CommitReceipt> selectWords(String commandId, List<String> ids) {
    _wordIds(ids);
    return _command(
      commandId,
      {'type': 'select', 'ids': ids.toSet().toList()..sort()},
      (tx, op) async {
        for (final id in ids.toSet()) {
          await _ensureWord(tx, id);
          await tx.update(
            'word_state',
            {'selected': 1},
            where: 'word_id=?',
            whereArgs: [id],
          );
        }
        return {'message': '已保存选词，记录跨词书保留。', 'count': ids.toSet().length};
      },
    );
  }

  void _wordIds(List<String> ids) {
    for (final id in ids) {
      _word(id);
    }
  }

  @override
  Future<CommitReceipt> updateWord(
    String commandId,
    String id, {
    WordDisposition? disposition,
    bool? favorite,
    String? note,
  }) {
    _word(id);
    if ((note?.length ?? 0) > 2000) {
      throw const StudyFailure('INVALID_ARGUMENT', '笔记过长。');
    }
    return _command(
      commandId,
      {
        'type': 'word',
        'id': id,
        'disposition': disposition?.name,
        'favorite': favorite,
        'note': note,
      },
      (tx, op) async {
        await _ensureWord(tx, id);
        await tx.update(
          'word_state',
          {
            if (disposition != null) 'disposition': disposition.name,
            if (favorite != null) 'favorite': favorite ? 1 : 0,
            'note': ?note,
          },
          where: 'word_id=?',
          whereArgs: [id],
        );
        return {'message': '单词状态已保存；历史未删除。'};
      },
    );
  }

  @override
  Future<CommitReceipt> proposePlan(String id, Map<String, dynamic> changes) =>
      _command(id, {'type': 'plan_propose', 'changes': changes}, (
        tx,
        op,
      ) async {
        final prefs = _decode((await tx.query('preferences')).single['data']);
        final proposal = _id('proposal');
        await tx.insert('proposals', {
          'id': proposal,
          'payload': jsonEncode(changes),
          'expected_revision': prefs['revision'],
          'status': 'pending',
          'expires_at': clock()
              .toUtc()
              .add(const Duration(hours: 24))
              .toIso8601String(),
        });
        return {
          'proposal_id': proposal,
          'expected_revision': prefs['revision'],
          'candidate': changes,
          'message': '计划草案已保存，尚未激活。',
        };
      });
  @override
  Future<CommitReceipt> activatePlan(
    String id,
    String proposalId,
  ) => _command(id, {'type': 'plan_activate', 'proposalId': proposalId}, (
    tx,
    op,
  ) async {
    final rows = await tx.query(
      'proposals',
      where: 'id=?',
      whereArgs: [proposalId],
    );
    if (rows.isEmpty ||
        rows.single['status'] != 'pending' ||
        DateTime.parse(rows.single['expires_at'] as String).isBefore(clock())) {
      throw const StudyFailure('ACTION_EXPIRED', '计划草案不存在或已失效。');
    }
    final previous = _decode((await tx.query('preferences')).single['data']);
    if (previous['revision'] != rows.single['expected_revision']) {
      throw const StudyFailure('VERSION_CONFLICT', '用户已修改计划，旧草案不能覆盖。');
    }
    final changes = _decode(rows.single['payload']);
    const allowed = {'newLimit', 'dailyLimit', 'budgetMinutes', 'mode'};
    if (changes.keys.any((k) => !allowed.contains(k))) {
      throw const StudyFailure('INVALID_ARGUMENT', '计划草案包含不支持字段。');
    }
    final next = {
      ...previous,
      ...changes,
      'revision': (previous['revision'] as int) + 1,
    };
    if (![0, 5, 10, 20, 30].contains(next['newLimit']) ||
        ![10, 20, 30, 50, 80].contains(next['dailyLimit']) ||
        ![10, 20, 30, 45].contains(next['budgetMinutes']) ||
        !['manual', 'assisted', 'managed'].contains(next['mode']) ||
        (next['dailyLimit'] as int) > (previous['dailyLimit'] as int) ||
        (next['budgetMinutes'] as int) > (previous['budgetMinutes'] as int)) {
      throw const StudyFailure('AUTHORIZATION_REQUIRED', '扩大预算或无效参数需要在计划页确认。');
    }
    await tx.update('preferences', {'data': jsonEncode(next)}, where: 'id=1');
    await tx.update(
      'proposals',
      {'status': 'activated'},
      where: 'id=?',
      whereArgs: [proposalId],
    );
    return {
      'proposal_id': proposalId,
      'revision': next['revision'],
      'message': '已激活计划草案。',
    };
  });
  @override
  Future<CommitReceipt> updatePreferences(
    String commandId,
    Map<String, dynamic> changes, {
    required int expectedRevision,
  }) => _command(
    commandId,
    {
      'type': 'preferences',
      'changes': changes,
      'expectedRevision': expectedRevision,
    },
    (tx, op) async {
      final previous = _decode((await tx.query('preferences')).single['data']);
      if (previous['revision'] != expectedRevision) {
        throw const StudyFailure('VERSION_CONFLICT', '计划已被修改，请刷新后重试。');
      }
      const allowed = {
        'bookId',
        'dailyLimit',
        'newLimit',
        'budgetMinutes',
        'direction',
        'order',
        'mode',
        'quiet',
        'goal',
      };
      if (changes.keys.any((k) => !allowed.contains(k))) {
        throw const StudyFailure('INVALID_ARGUMENT', '不支持的设置项。');
      }
      final next = {...previous, ...changes, 'revision': expectedRevision + 1};
      if (!catalog.books.any((b) => b.id == next['bookId']) ||
          ![10, 20, 30, 50, 80].contains(next['dailyLimit']) ||
          ![0, 5, 10, 20, 30].contains(next['newLimit']) ||
          ![10, 20, 30, 45].contains(next['budgetMinutes']) ||
          !['en-cn', 'cn-en', 'spell', 'listen'].contains(next['direction']) ||
          !['book', 'random', 'review'].contains(next['order']) ||
          !['manual', 'assisted', 'managed'].contains(next['mode']) ||
          next['quiet'] is! bool ||
          next['goal'] is! String) {
        throw const StudyFailure('INVALID_ARGUMENT', '计划设置无效。');
      }
      await tx.update('preferences', {'data': jsonEncode(next)}, where: 'id=1');
      return {'revision': expectedRevision + 1, 'message': '计划偏好已保存。'};
    },
  );
  @override
  Future<CommitReceipt> recordAttempt(String id, AttemptEvidence evidence) =>
      _recordAttempt(this, id, evidence);
  @override
  Future<CommitReceipt> addReview(
    String id,
    String wordId,
    StudySkill skill, {
    required String source,
    DateTime? requestedDue,
  }) => _addReview(this, id, wordId, skill, source, requestedDue);
  @override
  Future<CommitReceipt> schedule(
    String id,
    String pointId,
    DateTime dueAt, {
    required int expectedRevision,
  }) => _schedule(this, id, pointId, dueAt, expectedRevision);
  @override
  Future<CommitReceipt> undo(String id, String operationId) =>
      _undo(this, id, operationId);
  @override
  Future<CommitReceipt?> receipt(String id) async {
    final rows = await database.query(
      'commands',
      where: 'command_id=?',
      whereArgs: [id],
    );
    return rows.isEmpty ? null : CommitReceipt(_decode(rows.single['receipt']));
  }

  @override
  Future<CommitReceipt> controlSession(
    String id,
    String action, {
    Map<String, dynamic>? session,
  }) => _command(
    id,
    {'type': 'session_control', 'action': action, 'session': session},
    (tx, op) async {
      if (!{'start', 'pause', 'resume'}.contains(action)) {
        throw const StudyFailure('INVALID_ARGUMENT', '学习控制参数无效。');
      }
      final previous = await tx.query('checkpoints');
      final checkpoint =
          session ??
          (previous.isEmpty ? null : _decode(previous.single['payload']));
      if (checkpoint == null) {
        throw const StudyFailure('MODE_FORBIDDEN', '没有可执行学习任务。');
      }
      final tasks = checkpoint['tasks'];
      if (tasks is! List || tasks.isEmpty || tasks.length > 80) {
        throw const StudyFailure('INVALID_ARGUMENT', '学习队列无效。');
      }
      for (final raw in tasks) {
        final item = Map<String, dynamic>.from(raw as Map);
        _word(item['wordId'] as String);
        StudySkill.values.byName(item['skill'] as String);
        await _ensureWord(tx, item['wordId'] as String);
        await tx.update(
          'word_state',
          {'selected': 1},
          where: 'word_id=?',
          whereArgs: [item['wordId']],
        );
      }
      await tx.insert('checkpoints', {
        'id': 1,
        'payload': jsonEncode({
          ...checkpoint,
          'state': action == 'pause' ? 'paused' : 'running',
        }),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return {
        'message': action == 'pause' ? '学习已暂停，进度已保存。' : '学习任务已准备，请从今日页继续。',
        'session_status': action == 'pause' ? 'paused' : 'running',
      };
    },
  );
  @override
  Future<CommitReceipt> endSession(String id) =>
      _command(id, {'type': 'end_session'}, (tx, op) async {
        await tx.delete('checkpoints');
        return {'message': '本轮学习已结束，历史学习记录已保留。'};
      });
  @override
  Future<void> saveSession(Map<String, dynamic>? session) =>
      database.transaction((tx) async {
        _checkLease();
        if (session == null) {
          await tx.delete('checkpoints');
        } else {
          await tx.insert('checkpoints', {
            'id': 1,
            'payload': jsonEncode(session),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        _checkLease();
      });
  @override
  Future<Map<String, dynamic>> exportBackup() async => database.transaction(
    (tx) async => {
      'schema': 1,
      'namespace': 'english',
      'createdAt': clock().toUtc().toIso8601String(),
      'tables': {for (final name in tables) name: await tx.query(name)},
    },
  );
  @override
  Future<void> restoreBackup(Map<String, dynamic> backup) async {
    if (backup['schema'] != 1 ||
        backup['namespace'] != 'english' ||
        backup['tables'] is! Map) {
      throw const StudyFailure('INVALID_ARGUMENT', '不是有效英语学习备份。');
    }
    final values = Map<String, dynamic>.from(backup['tables'] as Map);
    if (values.keys.length != tables.length ||
        !tables.every(values.containsKey)) {
      throw const StudyFailure('INVALID_ARGUMENT', '备份表不完整。');
    }
    for (final name in tables) {
      if (values[name] is! List) {
        throw const StudyFailure('INVALID_ARGUMENT', '备份结构无效。');
      }
      for (final raw in values[name] as List) {
        if (raw is! Map) {
          throw const StudyFailure('INVALID_ARGUMENT', '备份记录无效。');
        }
        final id = raw['word_id'];
        if (id != null) _word(id as String);
      }
    }
    await _validateStudyBackup(this, values);
    await database.transaction((tx) async {
      for (final name in tables.reversed) {
        await tx.delete(name);
      }
      for (final name in tables) {
        for (final row in values[name] as List) {
          await tx.insert(name, Map<String, Object?>.from(row as Map));
        }
      }
    });
  }

  @override
  Future<CommitReceipt> startExam(String id, Map<String, dynamic> config) =>
      _startExam(this, id, config);
  @override
  Future<void> saveExamDraft(String examId, Map<String, String> answers) =>
      database.transaction((tx) async {
        _checkLease();
        final rows = await tx.query(
          'exams',
          where: 'id=?',
          whereArgs: [examId],
        );
        if (rows.isEmpty || rows.single['status'] != 'active') {
          throw const StudyFailure('MODE_FORBIDDEN', '该场考试当前不可保存作答。');
        }
        final ids = (_decode(rows.single['config'])['items'] as List)
            .map((q) => (q as Map)['id'])
            .toSet();
        if (answers.keys.any((id) => !ids.contains(id)) ||
            answers.values.any((a) => a.length > 2000)) {
          throw const StudyFailure('INVALID_ARGUMENT', '考试答案字段无效。');
        }
        await tx.update(
          'exams',
          {'answers': jsonEncode(answers)},
          where: 'id=?',
          whereArgs: [examId],
        );
        _checkLease();
      });
  @override
  Future<CommitReceipt> submitExam(
    String id,
    String examId,
    Map<String, String> answers,
  ) => _submitExam(this, id, examId, answers);
  @override
  Future<CommitReceipt> gradeExam(String id, String examId) =>
      _gradeExam(this, id, examId);
  @override
  Future<CommitReceipt> publishExam(String id, String examId) =>
      _publishExam(this, id, examId);
  @override
  Future<void> close() => database.close();
}
