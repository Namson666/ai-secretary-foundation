import 'package:flutter/services.dart';
import 'package:mcp_dart/mcp_dart.dart';

import 'web_search_result_parser.dart';
import 'web_search_service.dart';

class BailianWebSearchService implements WebSearchService {
  static final Uri endpoint = Uri.parse(
    'https://dashscope.aliyuncs.com/api/v1/mcps/WebSearch/mcp',
  );

  final Future<String?> Function() _readApiKey;

  BailianWebSearchService({Future<String?> Function()? readApiKey})
    : _readApiKey = readApiKey ?? _getApiKey;

  static Future<String?> _getApiKey() async {
    const channel = MethodChannel('com.namson.ai_secretary/config');
    return channel.invokeMethod<String>('getApiKey', {
      'key': 'bailian_api_key',
    });
  }

  @override
  Future<List<WebSearchHit>> search(String query) async {
    final key = await _readApiKey();
    if (key == null || key.isEmpty) {
      throw StateError('Bailian API key is not configured');
    }

    final client = McpClient(
      const Implementation(name: 'ai-assistant-search', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.legacy),
    );
    try {
      await client
          .connect(
            StreamableHttpClientTransport(
              endpoint,
              opts: StreamableHttpClientTransportOptions(
                requestInit: {
                  'headers': {'Authorization': 'Bearer $key'},
                },
              ),
            ),
          )
          .timeout(const Duration(seconds: 10));
      final available = await client.listTools().timeout(
        const Duration(seconds: 8),
      );
      final searchTools = available.tools.where(
        (tool) => tool.name.toLowerCase().contains('search'),
      );
      if (searchTools.isEmpty) {
        throw StateError('Bailian WebSearch tool is unavailable');
      }
      final result = await client.callTool(
        CallToolRequest(
          name: searchTools.first.name,
          arguments: {'query': query},
        ),
        options: RequestOptions(timeout: const Duration(seconds: 18)),
      );
      if (result.isError == true) {
        throw StateError('Bailian WebSearch returned an error');
      }
      final hits = WebSearchResultParser.parse(result.toJson());
      if (hits.isEmpty) {
        throw const FormatException('No attributed web search results');
      }
      return hits;
    } finally {
      try {
        await client.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        // The search result is more important than a failed session close.
      }
    }
  }
}
