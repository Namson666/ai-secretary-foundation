import 'package:ai_secretary/core/search/web_search_module.dart';
import 'package:ai_secretary/core/search/web_search_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSearch implements WebSearchService {
  String? lastQuery;

  @override
  Future<List<WebSearchHit>> search(String query) async {
    lastQuery = query;
    return [
      WebSearchHit(
        title: '官方资料',
        url: Uri.parse('https://example.org/update'),
        snippet: '更新摘要',
      ),
    ];
  }
}

void main() {
  test('search stays out of routine conversation', () {
    final module = WebSearchModule(_FakeSearch());
    expect(module.matches('今天心情不错'), isFalse);
    expect(module.matches('你好，聊聊电影'), isFalse);
    expect(module.matches('帮我联网查最新研究'), isTrue);
  });

  test('search validates input and returns attributed hits', () async {
    final service = _FakeSearch();
    final module = WebSearchModule(service);
    final invalid = await module.invoke(
      WebSearchModule.toolName,
      {'query': '  '},
      sessionId: 's',
      turnId: 't',
    );
    expect(invalid['error'], isNotNull);
    expect(service.lastQuery, isNull);

    final result = await module.invoke(
      WebSearchModule.toolName,
      {'query': '  最新研究  '},
      sessionId: 's',
      turnId: 't',
    );
    expect(service.lastQuery, '最新研究');
    expect(
      (result['results'] as List).single['url'],
      'https://example.org/update',
    );
    expect(result['searched_at'], isNotNull);
  });
}
