import 'dart:convert';

import 'package:ai_secretary/services/llm_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ChatAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': '你好'},
          },
        ],
      }),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const config = MethodChannel('com.namson.ai_secretary/config');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(config, null));

  test(
    'selected model follows settings changes without recreating service',
    () {
      var selected = 'MiniMax-M2.7-highspeed';
      final service = LlmService(model: () => selected);
      expect(service.selectedModel, 'MiniMax-M2.7-highspeed');
      selected = 'MiniMax-M3.1-Flash-Preview';
      expect(service.selectedModel, 'MiniMax-M3.1-Flash-Preview');
    },
  );

  test('DeepSeek and MiniMax use separate URLs and cached API keys', () async {
    var selected = 'deepseek-flash';
    final keys = <String>[];
    messenger.setMockMethodCallHandler(config, (call) async {
      final key = (call.arguments as Map)['key'] as String;
      keys.add(key);
      return 'test-$key-key';
    });
    final adapter = _ChatAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final service = LlmService(model: () => selected, dio: dio);
    const messages = <Map<String, dynamic>>[
      {'role': 'user', 'content': '你好'},
    ];
    await service.requestToolTurn(messages, []);
    expect(adapter.requests.last.uri.host, 'api.deepseek.com');
    expect(
      adapter.requests.last.headers['Authorization'],
      'Bearer test-deepseek-key',
    );
    expect((adapter.requests.last.data as Map)['model'], 'deepseek-flash');
    expect((adapter.requests.last.data as Map)['thinking'], {
      'type': 'disabled',
    });

    selected = 'MiniMax-M3.1-Flash-Preview';
    await service.requestToolTurn(messages, []);
    expect(adapter.requests.last.uri.host, 'api.minimaxi.com');
    expect((adapter.requests.last.data as Map).containsKey('tools'), isFalse);
    expect(
      adapter.requests.last.headers['Authorization'],
      'Bearer test-minimax-key',
    );
    expect((adapter.requests.last.data as Map)['reasoning_effort'], 'low');

    selected = 'deepseek-v4-pro';
    await service.requestToolTurn(messages, []);
    expect((adapter.requests.last.data as Map)['model'], 'deepseek-v4-pro');
    expect((adapter.requests.last.data as Map)['reasoning_effort'], 'low');
    expect(keys, ['deepseek', 'minimax']);
  });

  test('sanitizeAssistantContent removes complete reasoning blocks', () {
    final content = LlmService.sanitizeAssistantContent(
      '<think>private reasoning</think>\n\n你好，我可以帮你记录训练。',
    );

    expect(content, '你好，我可以帮你记录训练。');
  });

  test('sanitizeAssistantContent removes MEMORY control tags', () {
    final content = LlmService.sanitizeAssistantContent(
      '已记录身高。\n[MEMORY: height=182cm, category=health, importance=high]\n继续训练吧。',
    );

    expect(content, '已记录身高。\n\n继续训练吧。');
    expect(content, isNot(contains('[MEMORY:')));
  });

  test('sanitizeAssistantContent removes voice tone control tags', () {
    expect(LlmService.sanitizeAssistantContent('太好了！[TONE:happy]'), '太好了！');
  });

  test('MemoryTagStreamFilter removes split MEMORY tags', () {
    final filter = MemoryTagStreamFilter();
    final visible = StringBuffer();

    visible
      ..write(filter.add('已记录'))
      ..write(filter.add('[MEM'))
      ..write(filter.add('ORY: height=182cm, category=health'))
      ..write(filter.add(', importance=high]'))
      ..write(filter.add('，之后会参考。'))
      ..write(filter.close());

    expect(visible.toString(), '已记录，之后会参考。');
  });

  test('ReasoningBlockStreamFilter removes split reasoning blocks', () {
    final filter = ReasoningBlockStreamFilter();
    final visible = StringBuffer();

    visible
      ..write(filter.add('<thi'))
      ..write(filter.add('nk>private'))
      ..write(filter.add(' reasoning</th'))
      ..write(filter.add('ink>\n\n你好'))
      ..write(filter.add('，训练已记录。'))
      ..write(filter.close());

    expect(visible.toString().trim(), '你好，训练已记录。');
  });
}
