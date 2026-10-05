import 'dart:collection';

enum StudySkill { meaning, production, spelling, listening, pronunciation }

enum RecallGrade { again, hard, good, easy }

enum WordDisposition { active, familiar, paused }

class StudyWord {
  const StudyWord({
    required this.id,
    required this.word,
    required this.meaning,
    this.ipa = '',
    this.type = '',
    this.definition = '',
    this.example = '',
    this.translation = '',
    this.hint = '',
    this.source = '',
    this.exampleSource = '',
  });
  final String id,
      word,
      meaning,
      ipa,
      type,
      definition,
      example,
      translation,
      hint,
      source,
      exampleSource;
  factory StudyWord.fromJson(Map<String, dynamic> value) => StudyWord(
    id: value['id'] as String,
    word: value['word'] as String,
    meaning: value['meaning'] as String,
    ipa: value['ipa'] as String? ?? '',
    type: value['type'] as String? ?? '',
    definition: value['definition'] as String? ?? '',
    example: value['example'] as String? ?? '',
    translation: value['translation'] as String? ?? '',
    hint: value['hint'] as String? ?? '',
    source: value['sourceLabel'] as String? ?? '',
    exampleSource: value['exampleSource'] as String? ?? '',
  );
}

class StudyBook {
  StudyBook({
    required this.id,
    required this.title,
    required this.subtitle,
    required List<String> wordIds,
  }) : wordIds = List.unmodifiable(wordIds);
  final String id, title, subtitle;
  final List<String> wordIds;
  factory StudyBook.fromJson(Map<String, dynamic> value) => StudyBook(
    id: value['id'] as String,
    title: value['title'] as String,
    subtitle: value['subtitle'] as String,
    wordIds: (value['ids'] as List).cast<String>(),
  );
}

class StudyCatalog {
  StudyCatalog(List<StudyWord> entries, List<StudyBook> entriesBooks)
    : words = UnmodifiableMapView({for (final w in entries) w.id: w}),
      books = List.unmodifiable(entriesBooks) {
    if (words.length != entries.length ||
        words.isEmpty ||
        books.isEmpty ||
        books.any((b) => b.wordIds.any((id) => !words.containsKey(id)))) {
      throw const FormatException('Invalid vocabulary catalog');
    }
  }
  final Map<String, StudyWord> words;
  final List<StudyBook> books;
  factory StudyCatalog.fromJson(Map<String, dynamic> value) => StudyCatalog(
    (value['words'] as List)
        .map((v) => StudyWord.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    (value['books'] as List)
        .map((v) => StudyBook.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
  );
}

class WordProgress {
  const WordProgress({
    required this.wordId,
    required this.selected,
    required this.disposition,
    this.favorite = false,
    this.note = '',
    this.introduced = false,
  });
  final String wordId, note;
  final bool selected, favorite, introduced;
  final WordDisposition disposition;
}

class ReviewPoint {
  const ReviewPoint({
    required this.id,
    required this.wordId,
    required this.skill,
    required this.status,
    required this.revision,
    this.dueAt,
  });
  final String id, wordId, status;
  final StudySkill skill;
  final int revision;
  final DateTime? dueAt;
}

class StudyPreferences {
  const StudyPreferences({
    this.bookId = 'daily',
    this.dailyLimit = 50,
    this.newLimit = 20,
    this.budgetMinutes = 20,
    this.direction = 'en-cn',
    this.order = 'book',
    this.mode = 'assisted',
    this.timezone = 'Asia/Shanghai',
    this.quiet = false,
    this.goal = '在日常场景里，自信地说出来。',
    this.revision = 0,
  });
  final String bookId, direction, order, mode, timezone, goal;
  final int dailyLimit, newLimit, budgetMinutes, revision;
  final bool quiet;
  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'dailyLimit': dailyLimit,
    'newLimit': newLimit,
    'budgetMinutes': budgetMinutes,
    'direction': direction,
    'order': order,
    'mode': mode,
    'timezone': timezone,
    'quiet': quiet,
    'goal': goal,
    'revision': revision,
  };
  factory StudyPreferences.fromJson(Map<String, dynamic> v) => StudyPreferences(
    bookId: v['bookId'] as String? ?? 'daily',
    dailyLimit: v['dailyLimit'] as int? ?? 50,
    newLimit: v['newLimit'] as int? ?? 20,
    budgetMinutes: v['budgetMinutes'] as int? ?? 20,
    direction: v['direction'] as String? ?? 'en-cn',
    order: v['order'] as String? ?? 'book',
    mode: v['mode'] as String? ?? 'assisted',
    timezone: v['timezone'] as String? ?? 'Asia/Shanghai',
    quiet: v['quiet'] as bool? ?? false,
    goal: v['goal'] as String? ?? '',
    revision: v['revision'] as int? ?? 0,
  );
}

class StudySnapshot {
  StudySnapshot({
    required this.preferences,
    required Map<String, WordProgress> progress,
    required List<ReviewPoint> reviews,
    required this.attemptCount,
    required this.independentSuccessCount,
    required this.todayAttempts,
    required this.todayNewIntroductions,
    required this.weekAttempts,
    required this.session,
    required this.exams,
  }) : progress = Map.unmodifiable(progress),
       reviews = List.unmodifiable(reviews);
  final StudyPreferences preferences;
  final Map<String, WordProgress> progress;
  final List<ReviewPoint> reviews;
  final int attemptCount,
      independentSuccessCount,
      todayAttempts,
      todayNewIntroductions;
  final Map<String, int> weekAttempts;
  final Map<String, dynamic>? session;
  final List<Map<String, dynamic>> exams;
}

class CommitReceipt {
  CommitReceipt(this.values);
  final Map<String, dynamic> values;
  bool get committed => values['status'] == 'committed';
  String get operationId => values['operation_id'] as String? ?? '';
  String get message => values['message'] as String? ?? '';
  String? get pointId => values['point_id'] as String?;
}

class StudyFailure implements Exception {
  const StudyFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

class AttemptEvidence {
  const AttemptEvidence({
    required this.attemptId,
    required this.wordId,
    required this.skill,
    required this.grade,
    required this.independent,
    required this.hinted,
    required this.source,
    required this.answer,
    this.correct,
    this.reviewPointId,
  });
  final String attemptId, wordId, source, answer;
  final String? reviewPointId;
  final StudySkill skill;
  final RecallGrade grade;
  final bool independent, hinted;
  final bool? correct;
  factory AttemptEvidence.fromJson(Map<String, dynamic> value) =>
      AttemptEvidence(
        attemptId: value['attemptId'] as String,
        wordId: value['wordId'] as String,
        skill: StudySkill.values.byName(value['skill'] as String),
        grade: RecallGrade.values.byName(value['grade'] as String),
        independent: value['independent'] as bool,
        hinted: value['hinted'] as bool,
        source: value['source'] as String,
        answer: value['answer'] as String,
        correct: value['correct'] as bool?,
        reviewPointId: value['reviewPointId'] as String?,
      );
  bool get successfulIndependent =>
      independent && !hinted && correct != false && grade != RecallGrade.again;
  Map<String, dynamic> toJson() => {
    'attemptId': attemptId,
    'wordId': wordId,
    'skill': skill.name,
    'grade': grade.name,
    'independent': independent,
    'hinted': hinted,
    'source': source,
    'answer': answer,
    'correct': correct,
    'reviewPointId': reviewPointId,
  };
}
