import 'dart:convert';

import 'package:ai_secretary/features/study_runtime/study_cloud_client.dart';
import 'package:ai_secretary/features/study_runtime/study_conversation_runtime.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversation_runtime_test.dart' show TestAsr, TestTts;

class ProbeAdapter implements HttpClientAdapter {
  int count = 0;
  final requests = <Map<String, dynamic>>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(Map<String, dynamic>.from(options.data as Map));
    count++;
    final message = count == 1
        ? {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_a',
                'type': 'function',
                'function': {'name': 'save', 'arguments': '{}'},
              },
              {
                'id': 'call_b',
                'type': 'function',
                'function': {'name': 'save', 'arguments': '{}'},
              },
            ],
          }
        : {'role': 'assistant', 'content': 'NEXT_OK'};
    return ResponseBody.fromString(
      jsonEncode({
        'choices': [
          {'message': message},
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
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.namson.ai_secretary/config'),
          (_) async => 'non-secret-test-token',
        );
  });
  for (final failure in ['cancel', 'throw']) {
    test(
      'multi-tool $failure preserves committed receipt and pairs cancelled tools next turn',
      () async {
        final adapter = ProbeAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        final cloud = StudyCloudClient(dio: dio);
        late StudyConversationRuntime runtime;
        var calls = 0;
        runtime = StudyConversationRuntime(
          asr: TestAsr(),
          tts: TestTts(),
          cloud: cloud,
          tools: [
            {
              'type': 'function',
              'function': {'name': 'save'},
            },
          ],
          onTool: (_, _, context) async {
            calls++;
            if (calls == 1) {
              if (failure == 'cancel') await runtime.cancelHold();
              return {'status': 'committed', 'operation_id': 'op_actual'};
            }
            throw StateError('action rejected');
          },
        );
        await runtime.sendText('save');
        await runtime.sendText('undo the last operation');
        final history = adapter.requests.last['messages'] as List;
        final toolMessages = history
            .where((m) => (m as Map)['role'] == 'tool')
            .toList();
        expect(toolMessages.map((m) => m['tool_call_id']).toSet(), {
          'call_a',
          'call_b',
        });
        expect(
          jsonDecode(toolMessages.first['content'])['operation_id'],
          'op_actual',
        );
        expect(jsonDecode(toolMessages.last['content'])['status'], 'cancelled');
        expect(cloud.receipts.single['operation_id'], 'op_actual');
        expect(runtime.messages.last.text, 'NEXT_OK');
        await runtime.close();
        runtime.dispose();
      },
    );
  }
}
