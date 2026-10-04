import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../core/utils/constants.dart';
import '../core/utils/logger.dart';

class LlmService {
  late final Dio _dio;
  final Map<String, String> _cachedApiKeys = {};
  final String Function()? model;

  String get selectedModel => model?.call() ?? AppConstants.llmModel;

  static bool isDeepSeekModel(String model) => model.startsWith('deepseek-');

  String get selectedBaseUrl => isDeepSeekModel(selectedModel)
      ? AppConstants.deepSeekBaseUrl
      : AppConstants.llmBaseUrl;

  String get _apiPath => '$selectedBaseUrl/chat/completions';

  Map<String, dynamic> get _modelOptions => {
    'model': selectedModel,
    if (selectedModel == 'MiniMax-M3.1-Flash-Preview')
      'reasoning_effort': 'low',
    if (selectedModel == 'deepseek-flash') 'thinking': {'type': 'disabled'},
    if (selectedModel == 'deepseek-v4-pro') 'reasoning_effort': 'low',
  };

  LlmService({this.model, Dio? dio}) {
    _dio =
        dio ??
        Dio(
          BaseOptions(
            baseUrl: AppConstants.llmBaseUrl,
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 60),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'text/event-stream',
            },
          ),
        );
  }

  /// Keep the complete assistant message (including reasoning fields) between
  /// tool rounds, and never speak a tool preamble as a successful database write.
  Stream<String> sendWithTools({
    required List<Map<String, String>> messages,
    required String systemPrompt,
    required List<Map<String, dynamic>> tools,
    required Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
    onTool,
  }) async* {
    final history = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      ...messages,
    ];
    for (var round = 0; round < 5; round++) {
      final message = await requestToolTurn(history, tools);
      final calls = message['tool_calls'] as List? ?? [];
      if (calls.isEmpty) {
        final raw = message['content'] as String? ?? '';
        final filter = ReasoningBlockStreamFilter();
        final visible = filter.add(raw) + filter.close();
        if (visible.trim().isEmpty) throw const FormatException('AI 未返回有效内容');
        yield visible;
        return;
      }
      if (calls.length > 8) throw const FormatException('工具调用过多，请缩小请求范围');
      history.add(message);
      for (final item in calls) {
        final call = Map<String, dynamic>.from(item as Map);
        Map<String, dynamic> result;
        try {
          final f = call['function'] as Map;
          final args = jsonDecode(f['arguments'] as String);
          if (args is! Map<String, dynamic>) {
            throw const FormatException('参数不是对象');
          }
          result = await onTool(f['name'] as String, args);
        } on FormatException catch (e) {
          result = {'error': e.message};
        }
        history.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': jsonEncode(result),
        });
      }
    }
    throw const FormatException('本次查询步骤过多，请指定一个动作或更短时间范围');
  }

  Future<Map<String, dynamic>> requestToolTurn(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
  ) async {
    final key = await _getApiKey();
    if (key == null || key.isEmpty) {
      throw Exception(
        '${isDeepSeekModel(selectedModel) ? 'DeepSeek' : 'MiniMax'} API key not configured',
      );
    }
    final response = await _dio.post<Map<String, dynamic>>(
      _apiPath,
      options: Options(
        headers: {'Authorization': 'Bearer $key', 'Accept': 'application/json'},
      ),
      data: {
        ..._modelOptions,
        'messages': messages,
        if (tools.isNotEmpty) 'tools': tools,
        if (tools.isNotEmpty) 'tool_choice': 'auto',
        'stream': false,
      },
    );
    final choices = response.data?['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      throw const FormatException('AI 服务未返回结果');
    }
    return Map<String, dynamic>.from((choices.first as Map)['message'] as Map);
  }

  /// Remove model control blocks before content reaches UI, storage, RAG, or TTS.
  static String sanitizeAssistantContent(String content) {
    return content
        .replaceAll(
          RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\[MEMORY:\s*[\s\S]*?\]', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[TONE:\s*[a-z]+\s*\]', caseSensitive: false), '')
        .trim();
  }

  Future<String?> _getApiKey() async {
    final provider = isDeepSeekModel(selectedModel) ? 'deepseek' : 'minimax';
    if (_cachedApiKeys.containsKey(provider)) return _cachedApiKeys[provider];

    try {
      const channel = MethodChannel('com.namson.ai_secretary/config');
      final key = await channel.invokeMethod<String>('getApiKey', {
        'key': provider,
      });
      if (key != null && key.isNotEmpty) {
        _cachedApiKeys[provider] = key;
      }
      return key;
    } on MissingPluginException {
      Logger.w(
        'LlmService',
        'MethodChannel not available (likely non-mobile platform)',
      );
      return null;
    } catch (e) {
      Logger.e('LlmService', 'Failed to get API key: $e');
      return null;
    }
  }

  /// Send a message to MiniMax and return a stream of response tokens.
  Stream<String> sendMessage({
    required List<Map<String, String>> messages,
    String? systemPrompt,
  }) async* {
    final apiKey = await _getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception(
        '${isDeepSeekModel(selectedModel) ? 'DeepSeek' : 'MiniMax'} API key not configured',
      );
    }

    final body = <String, dynamic>{
      ..._modelOptions,
      'messages': [
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        ...messages,
      ],
      'stream': true,
    };

    Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        _apiPath,
        data: body,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Authorization': 'Bearer $apiKey'},
        ),
      );
    } on DioException catch (e) {
      Logger.e('LlmService', 'Dio error: ${e.message}');
      if (e.response?.statusCode == 401) {
        throw Exception('API 密钥无效或已过期，请检查当前模型密钥配置');
      } else if (e.response?.statusCode == 404) {
        throw Exception('模型名称不正确，请联系管理员检查模型配置');
      } else if (e.response?.data != null) {
        final responseStr = e.response?.data.toString() ?? '';
        Logger.e('LlmService', 'API response body: $responseStr');
        throw Exception(
          'API 错误 (${e.response?.statusCode}): ${e.response?.statusMessage}',
        );
      } else if (e.type == DioExceptionType.connectionTimeout) {
        throw Exception('连接超时，请检查网络');
      } else if (e.type == DioExceptionType.receiveTimeout) {
        throw Exception('响应超时，请重试');
      }
      throw Exception('网络错误: ${e.message}');
    }

    final responseBody = response.data;
    if (responseBody == null) {
      throw Exception('Empty response from API');
    }

    final byteStream = responseBody.stream;
    String buffer = '';
    final contentFilter = ReasoningBlockStreamFilter();

    try {
      await for (final chunk in byteStream) {
        final decoded = utf8.decode(chunk, allowMalformed: true);
        buffer += decoded;

        // Process complete SSE lines from buffer
        while (buffer.contains('\n')) {
          final lineEnd = buffer.indexOf('\n');
          final line = buffer.substring(0, lineEnd).trim();
          buffer = buffer.substring(lineEnd + 1);

          if (line.isEmpty) continue;

          if (line.startsWith('data: ')) {
            final data = line.substring(6);
            if (data == '[DONE]') return;

            try {
              final json = jsonDecode(data) as Map<String, dynamic>;
              final choices = json['choices'] as List<dynamic>?;
              if (choices == null || choices.isEmpty) continue;

              final delta = choices[0] as Map<String, dynamic>?;
              if (delta == null) continue;

              final contentDelta = delta['delta'] as Map<String, dynamic>?;
              if (contentDelta == null) continue;

              final content = contentDelta['content'] as String?;
              if (content != null && content.isNotEmpty) {
                final visibleContent = contentFilter.add(content);
                if (visibleContent.isNotEmpty) {
                  yield visibleContent;
                }
              }
            } catch (e) {
              // Skip malformed JSON lines
              Logger.d('LlmService', 'SSE parse error: $e');
            }
          }
        }
      }

      final visibleRemainder = contentFilter.close();
      if (visibleRemainder.isNotEmpty) {
        yield visibleRemainder;
      }
    } catch (e) {
      Logger.e('LlmService', 'Stream error: $e');
      throw Exception('Stream interrupted: $e');
    }
  }

  /// Non-streaming call (for retry or simple requests).
  Future<String> sendMessageSync({
    required List<Map<String, String>> messages,
    String? systemPrompt,
    bool sanitize = true,
  }) async {
    final apiKey = await _getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception(
        '${isDeepSeekModel(selectedModel) ? 'DeepSeek' : 'MiniMax'} API key not configured',
      );
    }

    final body = <String, dynamic>{
      ..._modelOptions,
      'messages': [
        if (systemPrompt != null && systemPrompt.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        ...messages,
      ],
      'stream': false,
    };

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        _apiPath,
        data: body,
        options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      );

      final data = response.data;
      if (data == null) throw Exception('Empty response');

      final choices = data['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        throw Exception('No choices in response');
      }

      final message = choices[0] as Map<String, dynamic>;
      final content =
          (message['message'] as Map<String, dynamic>?)?['content'] as String?;
      final rawContent = content ?? '';
      return sanitize ? sanitizeAssistantContent(rawContent) : rawContent;
    } on DioException catch (e) {
      Logger.e('LlmService', 'Sync call error: ${e.message}');
      throw Exception('API error: ${e.message}');
    }
  }

  /// Returns diagnostic information about the current LLM configuration.
  Map<String, String> getDiagnosticInfo() {
    return {
      'baseUrl': selectedBaseUrl,
      ..._modelOptions,
      'hasApiKey':
          (_cachedApiKeys[isDeepSeekModel(selectedModel)
                          ? 'deepseek'
                          : 'minimax']
                      ?.isNotEmpty ??
                  false)
              .toString(),
    };
  }
}

class MemoryTagStreamFilter {
  static const _openTag = '[memory:';
  static const _closeTag = ']';

  String _pending = '';
  bool _insideMemoryTag = false;

  String add(String chunk) {
    _pending += chunk;
    final output = StringBuffer();

    while (_pending.isNotEmpty) {
      if (_insideMemoryTag) {
        final closeIndex = _pending.indexOf(_closeTag);
        if (closeIndex == -1) {
          _pending = '';
          break;
        }
        _pending = _pending.substring(closeIndex + _closeTag.length);
        _insideMemoryTag = false;
        continue;
      }

      final openIndex = _pending.toLowerCase().indexOf(_openTag);
      if (openIndex == -1) {
        final guard = _keepPossibleTagSuffix(_pending, _openTag);
        output.write(_pending.substring(0, _pending.length - guard.length));
        _pending = guard;
        break;
      }

      output.write(_pending.substring(0, openIndex));
      _pending = _pending.substring(openIndex + _openTag.length);
      _insideMemoryTag = true;
    }

    return output.toString();
  }

  String close() {
    if (_insideMemoryTag) {
      _pending = '';
      _insideMemoryTag = false;
      return '';
    }
    final remainder = _pending;
    _pending = '';
    return remainder;
  }

  static String _keepPossibleTagSuffix(String value, String tag) {
    final lower = value.toLowerCase();
    for (var length = tag.length - 1; length > 0; length--) {
      if (lower.length >= length &&
          tag.startsWith(lower.substring(lower.length - length))) {
        return value.substring(value.length - length);
      }
    }
    return '';
  }
}

class ReasoningBlockStreamFilter {
  static const _openTag = '<think>';
  static const _closeTag = '</think>';

  String _pending = '';
  bool _insideThinkBlock = false;

  String add(String chunk) {
    _pending += chunk;
    final output = StringBuffer();

    while (_pending.isNotEmpty) {
      if (_insideThinkBlock) {
        final closeIndex = _pending.toLowerCase().indexOf(_closeTag);
        if (closeIndex == -1) {
          _pending = _keepPossibleTagSuffix(_pending, _closeTag);
          break;
        }
        _pending = _pending.substring(closeIndex + _closeTag.length);
        _insideThinkBlock = false;
        continue;
      }

      final openIndex = _pending.toLowerCase().indexOf(_openTag);
      if (openIndex == -1) {
        final guard = _keepPossibleTagSuffix(_pending, _openTag);
        output.write(_pending.substring(0, _pending.length - guard.length));
        _pending = guard;
        break;
      }

      output.write(_pending.substring(0, openIndex));
      _pending = _pending.substring(openIndex + _openTag.length);
      _insideThinkBlock = true;
    }

    return output.toString();
  }

  String close() {
    if (_insideThinkBlock) {
      _pending = '';
      _insideThinkBlock = false;
      return '';
    }
    final remainder = _pending;
    _pending = '';
    return remainder;
  }

  static String _keepPossibleTagSuffix(String value, String tag) {
    final lower = value.toLowerCase();
    for (var length = tag.length - 1; length > 0; length--) {
      if (lower.length >= length &&
          tag.startsWith(lower.substring(lower.length - length))) {
        return value.substring(value.length - length);
      }
    }
    return '';
  }
}
