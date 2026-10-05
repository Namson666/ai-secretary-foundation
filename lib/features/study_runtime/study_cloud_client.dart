import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../services/llm_service.dart';
import 'study_conversation_runtime.dart';

/// Mobile configuration stays in the existing private native configuration channel.
/// This client has no health database, settings, RAG or training dependencies.
class StudyCloudClient {
  final Dio _dio;
  StudyCloudClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );
  CancelToken? _request;
  String? actualModel;
  Map<String, dynamic>? lastUsage;
  final List<List<Map<String, dynamic>>> _turns = [];
  final List<Map<String, dynamic>> _receipts = [];
  List<Map<String, dynamic>> get receipts => List.unmodifiable(_receipts);
  static const model = 'MiniMax-M3.1-Flash-Preview';

  Future<String> reply({
    required List<StudyChatMessage> messages,
    required StudyInputContext context,
    required List<Map<String, dynamic>> tools,
    required StudyToolHandler? onTool,
    required bool Function() isCurrent,
  }) async {
    const channel = MethodChannel('com.namson.ai_secretary/config');
    final key = await channel.invokeMethod<String>('getApiKey', {
      'key': 'minimax',
    });
    if (!isCurrent()) return '';
    if (key == null || key.isEmpty) throw StateError('对话服务未配置，可继续基础学习');
    final turn = <Map<String, dynamic>>[
      {'role': 'user', 'content': messages.last.text},
    ];
    _turns.add(turn);
    if (_turns.length > 6) _turns.removeAt(0);
    final history = <Map<String, dynamic>>[
      {'role': 'system', 'content': context.systemPrompt},
      ..._turns.expand((turn) => turn),
    ];
    final token = CancelToken();
    _request = token;
    try {
      for (var round = 0; round < 4; round++) {
        if (!isCurrent()) return '';
        final response = await _dio.post<Map<String, dynamic>>(
          'https://api.minimax.cn/v1/chat/completions',
          options: Options(headers: {'Authorization': 'Bearer $key'}),
          cancelToken: token,
          data: {
            'model': model,
            'reasoning_effort': 'low',
            'stream': false,
            'max_tokens': 1024,
            'messages': history,
            if (tools.isNotEmpty && onTool != null) 'tools': tools,
          },
        );
        if (!isCurrent()) return '';
        final returnedModel = response.data?['model'];
        if (returnedModel is String) actualModel = returnedModel;
        final usage = response.data?['usage'];
        if (usage is Map) {
          lastUsage = Map.unmodifiable(Map<String, dynamic>.from(usage));
        }
        final choices = response.data?['choices'];
        if (choices is! List || choices.isEmpty) {
          throw const FormatException('对话服务未返回结果');
        }
        final message = Map<String, dynamic>.from(
          (choices.first as Map)['message'] as Map,
        );
        final calls = message['tool_calls'] as List? ?? const [];
        if (calls.isEmpty) {
          final text = LlmService.sanitizeAssistantContent(
            message['content'] as String? ?? '',
          );
          if (text.isEmpty) throw const FormatException('对话服务未返回可显示内容');
          turn.add({'role': 'assistant', 'content': text});
          return text;
        }
        if (onTool == null || calls.length > 4) {
          throw const FormatException('本次动作太多，请每次指定一个操作');
        }
        history.add(message);
        turn.add(message);
        for (final raw in calls) {
          if (!isCurrent()) return '';
          final call = Map<String, dynamic>.from(raw as Map);
          final function = call['function'] as Map;
          final name = function['name'] as String;
          final allowed = tools.any(
            (t) => (t['function'] as Map?)?['name'] == name,
          );
          Map<String, dynamic> receipt;
          if (!allowed) {
            receipt = {'error': '该操作未启用'};
          } else {
            final args = jsonDecode(function['arguments'] as String);
            if (args is! Map<String, dynamic>) {
              throw const FormatException('操作参数无效');
            }
            receipt = await onTool(
              name,
              args,
              context.forToolCall(call['id'] as String),
            );
          }
          // A completed transaction is a fact even if the request was cancelled
          // immediately afterwards. Preserve that receipt for a later undo.
          final toolResult = <String, dynamic>{
            'role': 'tool',
            'tool_call_id': call['id'],
            'content': jsonEncode(receipt),
          };
          history.add(toolResult);
          turn.add(toolResult);
          _receipts.add(Map.unmodifiable(receipt));
          if (!isCurrent()) return '';
        }
      }
      throw const FormatException('操作步骤过多，请缩小本次请求');
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) return '';
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) throw StateError('对话服务鉴权失败，可继续基础学习');
      if (code == 404) throw StateError('所选模型当前不可用，可继续基础学习');
      throw StateError(code == null ? '网络连接失败，请稍后重试' : '对话服务错误（$code），请稍后重试');
    } finally {
      // Providers require one result for every declared tool call. Cancellation
      // or a rejected domain action must not poison the next conversation turn.
      final handled = turn
          .where((m) => m['role'] == 'tool')
          .map((m) => m['tool_call_id'])
          .toSet();
      final pending = turn.expand((m) => m['tool_calls'] as List? ?? const []);
      for (final raw in pending.toList()) {
        final id = (raw as Map)['id'];
        if (!handled.contains(id)) {
          turn.add({
            'role': 'tool',
            'tool_call_id': id,
            'content': jsonEncode({
              'status': 'cancelled',
              'message': '该操作未完成，不能报告为已提交',
            }),
          });
        }
      }
      if (identical(_request, token)) _request = null;
    }
  }

  void cancel() {
    _request?.cancel();
    _request = null;
  }

  void dispose() {
    cancel();
    _dio.close(force: true);
  }
}
