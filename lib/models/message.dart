class Message {
  final int? id;
  final String sessionId;
  final String role; // 'user' or 'assistant'
  final String content;
  final String? emotion;
  final int? tokenCount;
  final DateTime createdAt;

  Message({
    this.id,
    required this.sessionId,
    required this.role,
    required this.content,
    this.emotion,
    this.tokenCount,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory Message.fromMap(Map<String, dynamic> map) {
    return Message(
      id: map['id'] as int?,
      sessionId: map['session_id'] as String,
      role: map['role'] as String,
      content: map['content'] as String,
      emotion: map['emotion'] as String?,
      tokenCount: map['token_count'] as int?,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'session_id': sessionId,
      'role': role,
      'content': content,
      'emotion': emotion,
      'token_count': tokenCount,
      'created_at': createdAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'session_id': sessionId,
      'role': role,
      'content': content,
      'emotion': emotion,
      'token_count': tokenCount,
      'created_at': createdAt.toIso8601String(),
    };
  }

  Message copyWith({
    int? id,
    String? sessionId,
    String? role,
    String? content,
    String? emotion,
    int? tokenCount,
    DateTime? createdAt,
  }) {
    return Message(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content: content ?? this.content,
      emotion: emotion ?? this.emotion,
      tokenCount: tokenCount ?? this.tokenCount,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
}
