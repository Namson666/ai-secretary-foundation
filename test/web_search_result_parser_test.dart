import 'package:ai_secretary/core/search/web_search_result_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses nested JSON MCP search results and deduplicates URLs', () {
    final hits = WebSearchResultParser.parse({
      'content': [
        {
          'type': 'text',
          'text':
              '{"results":[{"title":"官方文档","link":"https://example.org/a","snippet":"资料摘要"},{"title":"重复","url":"https://example.org/a"},{"title":"无效","url":"javascript:alert(1)"}]}',
        },
      ],
    });
    expect(hits, hasLength(1));
    expect(hits.single.title, '官方文档');
    expect(hits.single.snippet, '资料摘要');
  });

  test('does not treat unattributed text as a source', () {
    expect(WebSearchResultParser.parse('这里没有来源链接'), isEmpty);
    expect(
      WebSearchResultParser.parse({
        'results': [
          {'title': '本地文件', 'url': 'file:///private/data'},
        ],
      }),
      isEmpty,
    );
  });
}
