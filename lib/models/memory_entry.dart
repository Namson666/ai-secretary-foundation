class MemoryEntry {
  final int? id;
  final String key;
  final String value;
  final String
  category; // health/fitness/life/work/career/emotion/family/schedule/finance
  final int importance; // 1-5
  final double confidence; // 0.0-1.0
  final String source; // user_input/ai_extract/manual/training_data
  final DateTime? lastConfirmedAt;
  final DateTime? expiresAt;
  final DateTime createdAt;

  MemoryEntry({
    this.id,
    required this.key,
    required this.value,
    this.category = 'life',
    this.importance = 3,
    this.confidence = 0.5,
    this.source = 'ai_extract',
    this.lastConfirmedAt,
    this.expiresAt,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory MemoryEntry.fromMap(Map<String, dynamic> map) {
    return MemoryEntry(
      id: map['id'] as int?,
      key: map['key'] as String,
      value: map['value'] as String,
      category: (map['category'] as String?) ?? 'life',
      importance: (map['importance'] as int?) ?? 3,
      confidence: (map['confidence'] as num?)?.toDouble() ?? 0.5,
      source: (map['source'] as String?) ?? 'ai_extract',
      lastConfirmedAt: _parseDateTime(map['last_confirmed_at']),
      expiresAt: _parseDateTime(map['expires_at']),
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'key': key,
      'value': value,
      'category': category,
      'importance': importance,
      'confidence': confidence,
      'source': source,
      'last_confirmed_at': lastConfirmedAt?.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }

  bool isActiveAt(DateTime now) {
    final expiry = expiresAt;
    return importance > 0 && (expiry == null || expiry.isAfter(now));
  }

  bool get isActive => isActiveAt(DateTime.now());

  MemoryEntry copyWith({
    int? id,
    String? key,
    String? value,
    String? category,
    int? importance,
    double? confidence,
    String? source,
    DateTime? lastConfirmedAt,
    DateTime? expiresAt,
    DateTime? createdAt,
    bool clearLastConfirmedAt = false,
    bool clearExpiresAt = false,
  }) {
    return MemoryEntry(
      id: id ?? this.id,
      key: key ?? this.key,
      value: value ?? this.value,
      category: category ?? this.category,
      importance: importance ?? this.importance,
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
      lastConfirmedAt: clearLastConfirmedAt
          ? null
          : (lastConfirmedAt ?? this.lastConfirmedAt),
      expiresAt: clearExpiresAt ? null : (expiresAt ?? this.expiresAt),
      createdAt: createdAt ?? this.createdAt,
    );
  }

  static DateTime? _parseDateTime(Object? value) {
    final raw = value?.toString();
    if (raw == null || raw.trim().isEmpty) return null;
    return DateTime.parse(raw);
  }
}
