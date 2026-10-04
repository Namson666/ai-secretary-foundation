class RagDocument {
  final int? id;
  final String docKey;
  final String sourceType;
  final String? sourceId;
  final String title;
  final String content;
  final String? metadataJson;
  final String? embeddingJson;
  final String? embeddingModel;
  final DateTime createdAt;
  final DateTime updatedAt;

  RagDocument({
    this.id,
    required this.docKey,
    required this.sourceType,
    this.sourceId,
    required this.title,
    required this.content,
    this.metadataJson,
    this.embeddingJson,
    this.embeddingModel,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  factory RagDocument.fromMap(Map<String, dynamic> map) {
    return RagDocument(
      id: map['id'] as int?,
      docKey: map['doc_key'] as String,
      sourceType: map['source_type'] as String,
      sourceId: map['source_id'] as String?,
      title: map['title'] as String? ?? '',
      content: map['content'] as String? ?? '',
      metadataJson: map['metadata_json'] as String?,
      embeddingJson: map['embedding_json'] as String?,
      embeddingModel: map['embedding_model'] as String?,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : DateTime.now(),
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'doc_key': docKey,
      'source_type': sourceType,
      'source_id': sourceId,
      'title': title,
      'content': content,
      'metadata_json': metadataJson,
      'embedding_json': embeddingJson,
      'embedding_model': embeddingModel,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  RagDocument copyWith({
    int? id,
    String? docKey,
    String? sourceType,
    String? sourceId,
    String? title,
    String? content,
    String? metadataJson,
    String? embeddingJson,
    String? embeddingModel,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return RagDocument(
      id: id ?? this.id,
      docKey: docKey ?? this.docKey,
      sourceType: sourceType ?? this.sourceType,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      content: content ?? this.content,
      metadataJson: metadataJson ?? this.metadataJson,
      embeddingJson: embeddingJson ?? this.embeddingJson,
      embeddingModel: embeddingModel ?? this.embeddingModel,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
