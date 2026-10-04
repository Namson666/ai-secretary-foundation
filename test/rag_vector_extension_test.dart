import 'package:ai_secretary/models/rag_document.dart';
import 'package:ai_secretary/services/embedding_service.dart';
import 'package:ai_secretary/services/rag_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Embeddings implements EmbeddingProvider {
  @override
  Future<List<double>> embed(String text) async => [1.0, 0.0];
}

class _ExternalIndex implements RagVectorIndex {
  @override
  Future<List<RagSearchResult>> search({
    required List<double> queryEmbedding,
    int limit = 8,
    double minScore = 0.18,
  }) async => [
    RagSearchResult(
      document: RagDocument(
        docKey: 'external_note:42',
        sourceType: 'external_note',
        title: '外部词表',
        content: 'word: example',
      ),
      score: 0.9,
    ),
  ];
}

void main() {
  // No SQLite FFI setup: the supplied extension owns its documents and storage.
  test('an external vector index does not require a local database', () async {
    final service = RagService(
      embeddingService: _Embeddings(),
      vectorIndex: _ExternalIndex(),
    );

    final results = await service.search('example');

    expect(results, hasLength(1));
    expect(results.single.document.docKey, 'external_note:42');
  });
}
