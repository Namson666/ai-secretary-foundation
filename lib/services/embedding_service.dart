import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../core/utils/constants.dart';
import '../core/utils/logger.dart';

abstract class EmbeddingProvider {
  Future<List<double>> embed(String text);
}

class EmbeddingService implements EmbeddingProvider {
  late final Dio _dio;
  String? _cachedApiKey;

  EmbeddingService() {
    _dio = Dio(
      BaseOptions(
        baseUrl: AppConstants.embeddingBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
        headers: {'Content-Type': 'application/json'},
      ),
    );
  }

  Future<String?> _getApiKey() async {
    if (_cachedApiKey != null) return _cachedApiKey;

    try {
      const channel = MethodChannel('com.namson.ai_secretary/config');
      final key = await channel.invokeMethod<String>('getApiKey', {
        'key': 'bailian_api_key',
      });
      if (key != null && key.isNotEmpty) {
        _cachedApiKey = key;
      }
      return key;
    } on MissingPluginException {
      Logger.w(
        'EmbeddingService',
        'MethodChannel not available (likely non-mobile platform)',
      );
      return null;
    } catch (e) {
      Logger.e('EmbeddingService', 'Failed to get API key: $e');
      return null;
    }
  }

  @override
  Future<List<double>> embed(String text) async {
    if (text.trim().isEmpty) return const [];

    final apiKey = await _getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      throw Exception('Bailian API key not configured');
    }

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '/embeddings',
        data: {
          'model': AppConstants.embeddingModel,
          'input': text,
          'encoding_format': 'float',
        },
        options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      );

      final data = response.data?['data'];
      if (data is! List || data.isEmpty) {
        throw Exception('Empty response from embedding API');
      }

      final embedding = (data.first as Map<String, dynamic>)['embedding'];
      if (embedding is! List) {
        throw Exception('Missing embedding vector');
      }

      return embedding.map((v) => (v as num).toDouble()).toList();
    } on DioException catch (e) {
      Logger.e('EmbeddingService', 'Dio error: ${e.message}');
      throw Exception('Embedding request failed: ${e.message}');
    }
  }
}
