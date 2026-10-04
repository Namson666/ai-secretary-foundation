// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/database/database_helper.dart';
import '../core/utils/logger.dart';
import '../models/memory_entry.dart';
import '../models/message.dart';
import 'llm_service.dart';
import 'memory_policy.dart';
import 'rag_service.dart';

class MemoryService {
  final DatabaseHelper _dbHelper;
  final LlmService? _llmService;
  final RagService _ragService;
  final MemoryPolicy _memoryPolicy;
  final bool includeHealthExtraction;

  /// Track when the current session started for summary trigger logic.
  DateTime? _sessionStartTime;
  int _sessionMessageCount = 0;

  MemoryService({
    DatabaseHelper? dbHelper,
    LlmService? llmService,
    RagService? ragService,
    MemoryPolicy? memoryPolicy,
    this.includeHealthExtraction = true,
  }) : _dbHelper = dbHelper ?? DatabaseHelper.instance,
       _llmService = llmService,
       _ragService = ragService ?? RagService(),
       _memoryPolicy = memoryPolicy ?? const MemoryPolicy();

  // ---------------------------------------------------------------------------
  // Context building
  // ---------------------------------------------------------------------------

  /// Build a comprehensive memory context string for system prompts.
  Future<String> buildContext({
    String? query,
    bool includeWorkoutHistory = false,
  }) async {
    final buffer = StringBuffer();

    // 1. User profile
    final profile = await _getUserProfile();
    if (profile != null) {
      buffer.writeln('用户档案：$profile');
    }

    // 2. Vector RAG retrieval
    if (query != null && query.trim().isNotEmpty) {
      final results = await _ragService.search(query, limit: 8);
      final ragContext = RagService.formatContext(
        includeWorkoutHistory
            ? results
            : results
                  .where(
                    (result) =>
                        result.document.sourceType != 'workout' &&
                        result.document.sourceType != 'conversation_message' &&
                        result.document.sourceType != 'conversation_summary',
                  )
                  .toList(),
      );
      if (ragContext.isNotEmpty) {
        buffer.writeln(ragContext);
      }
    }

    // 3. High-importance memories (importance >= 4)
    final importantFacts = includeWorkoutHistory
        ? await _getImportantFacts()
        : <MemoryEntry>[];
    if (importantFacts.isNotEmpty) {
      buffer.writeln('\n[重要信息]');
      for (final fact in importantFacts) {
        buffer.writeln('- ${fact.key}：${fact.value}');
      }
    }

    // 4. Query-related facts (keyword fallback)
    final relevantFacts = await _getRelevantFacts(query, limit: 12);
    if (relevantFacts.isNotEmpty) {
      buffer.writeln('\n[相关记忆检索]');
      for (final fact in relevantFacts) {
        buffer.writeln('- ${fact.key}：${fact.value}（类别：${fact.category}）');
      }
    }

    // 5. Recent facts ordered by importance desc
    final recentFacts = includeWorkoutHistory
        ? await _getRecentFacts(50)
        : <MemoryEntry>[];
    if (recentFacts.isNotEmpty) {
      buffer.writeln('\n[最近信息]');
      final relevantIds = relevantFacts
          .map((f) => f.id)
          .whereType<int>()
          .toSet();
      for (final fact
          in recentFacts.where((f) => !relevantIds.contains(f.id)).take(12)) {
        buffer.writeln('- ${fact.key}：${fact.value}（类别：${fact.category}）');
      }
    }

    // 6. Recent conversation summaries
    final summaries = includeWorkoutHistory
        ? await _getRecentSummaries(10)
        : <Map<String, dynamic>>[];
    for (final s in summaries) {
      buffer.writeln('\n对话摘要：${s['summary_text'] ?? ''}');
    }

    // 7. Recent phone workout records
    final workouts = includeWorkoutHistory
        ? await _getRecentWorkouts(5)
        : <Map<String, dynamic>>[];
    for (final w in workouts) {
      final workoutId = w['id'] as int?;
      final title = w['title'] ?? '';
      final date = w['created_at'] ?? '';
      final volume = (w['total_volume'] as num?)?.toDouble() ?? 0;
      final sets = w['total_sets'] ?? 0;
      final duration = ((w['duration'] as num?)?.toInt() ?? 0) ~/ 60;
      final note = w['note']?.toString();
      buffer.writeln(
        '\n训练记录：$title（$date），${volume.toStringAsFixed(0)}kg，$sets组，$duration分钟',
      );
      if (note != null && note.trim().isNotEmpty) {
        buffer.writeln('训练备注：$note');
      }
      if (workoutId != null) {
        final details = await _getWorkoutSetDetails(workoutId);
        if (details.isNotEmpty) {
          buffer.writeln('训练动作明细：${details.join('；')}');
        }
      }
    }

    final result = buffer.toString().trim();
    if (result.isEmpty) return '';
    return '\n[记忆上下文]\n$result';
  }

  // ---------------------------------------------------------------------------
  // AI response processing ([MEMORY:] tag extraction)
  // ---------------------------------------------------------------------------

  /// Extract [MEMORY:] tags from AI response text.
  List<String> extractMemoryTags(String aiResponse) {
    final regex = RegExp(r'\[MEMORY:\s*(.*?)\]');
    return regex.allMatches(aiResponse).map((m) => m.group(1)!.trim()).toList();
  }

  /// Parse a memory tag string into key=value pairs.
  Map<String, String> parseMemoryTag(String tag) {
    if (tag.contains('=')) {
      final parts = tag.split(',').map((s) => s.trim()).toList();
      final result = <String, String>{};
      for (final part in parts) {
        final eqIdx = part.indexOf('=');
        if (eqIdx > 0) {
          result[part.substring(0, eqIdx).trim()] = part
              .substring(eqIdx + 1)
              .trim();
        }
      }
      return result;
    }
    return {'value': tag};
  }

  /// Save a memory entry parsed from AI response.
  Future<void> saveFromTag(String tag) async {
    try {
      final parsed = parseMemoryTag(tag);
      final category = parsed['category'] ?? 'life';
      final importance = _parseImportance(parsed['importance']);
      final confidence = double.tryParse(parsed['confidence'] ?? '') ?? 0.7;

      if (parsed.containsKey('key') || parsed.containsKey('value')) {
        final key = parsed['key'] ?? tag.split(',')[0].trim();
        final value = parsed['value'] ?? tag;

        final entry = MemoryEntry(
          key: key,
          value: value,
          category: category,
          importance: importance,
          confidence: confidence,
          source: 'ai_extract',
        );

        await _saveMemory(entry);
        Logger.d('MemoryService', 'Saved memory: $key = $value');
        return;
      }

      const metadataKeys = {'category', 'importance', 'confidence', 'source'};
      final factEntries = parsed.entries.where(
        (entry) => !metadataKeys.contains(entry.key),
      );

      for (final fact in factEntries) {
        final entry = MemoryEntry(
          key: fact.key,
          value: fact.value,
          category: category,
          importance: importance,
          confidence: confidence,
          source: 'ai_extract',
        );

        await _saveMemory(entry);
        Logger.d('MemoryService', 'Saved memory: ${fact.key} = ${fact.value}');
      }
    } catch (e) {
      Logger.e('MemoryService', 'Failed to save memory from tag "$tag": $e');
    }
  }

  /// Extract, parse, and save all [MEMORY:] tags from AI response.
  Future<void> processAiResponse(String aiResponse) async {
    final tags = extractMemoryTags(aiResponse);
    for (final tag in tags) {
      await saveFromTag(tag);
    }
  }

  int _parseImportance(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == null || normalized.isEmpty) return 3;
    final numeric = int.tryParse(normalized);
    if (numeric != null) return numeric.clamp(1, 5);
    return switch (normalized) {
      'critical' || 'highest' || 'high' || '重要' || '高' => 5,
      'medium' || 'normal' || '中' || '一般' => 3,
      'low' || '低' => 1,
      _ => 3,
    };
  }

  // ---------------------------------------------------------------------------
  // Rule engine: auto-extract from user input
  // ---------------------------------------------------------------------------

  /// Extract structured information from user input using regex rules.
  Future<void> extractFromUserInput(String userInput) async {
    final nameMatch = RegExp(
      r'我叫([一-鿿]{2,4})|我是([一-鿿]{2,4})',
    ).firstMatch(userInput);
    if (nameMatch != null) {
      final name = nameMatch.group(1) ?? nameMatch.group(2) ?? '';
      if (name.isNotEmpty) {
        await _saveMemory(
          MemoryEntry(
            key: 'name',
            value: name,
            category: 'life',
            importance: 4,
            source: 'user_input',
          ),
        );
        await _upsertUserProfilePatch({'name': name});
      }
    }
    if (!includeHealthExtraction) return;
    // Weight: "我的体重84公斤" / "我现在82kg".
    // Avoid treating exercise loads such as "卧推50公斤" as body weight.
    final weightMatch =
        RegExp(
          r'(?:我的体重|体重|我现在|我目前|目前|现在|我重|我)\s*(?:是|有|重|大概|约)?\s*(\d+(?:\.\d+)?)\s*(?:公斤|kg)',
          caseSensitive: false,
        ).firstMatch(userInput) ??
        RegExp(
          r'\b(?:weight|body weight)\s*(?:is|=|to)?\s*(\d+(?:\.\d+)?)\s*(?:kg|kilograms?)?\b',
          caseSensitive: false,
        ).firstMatch(userInput);
    if (weightMatch != null) {
      final weight = weightMatch.group(1)!;
      final entry = MemoryEntry(
        key: 'weight',
        value: '$weight kg',
        category: 'health',
        importance: 4,
        source: 'user_input',
      );
      await _saveMemory(entry);
      await _upsertUserProfilePatch({'weight': double.tryParse(weight)});
      Logger.d('MemoryService', 'Auto-extracted weight: $weight kg');
    }

    // Height: "我身高175" / "把身高改成180"
    final heightMatch =
        RegExp(r'身高\s*(?:是|改成|改为|设为|=)?\s*(\d+)').firstMatch(userInput) ??
        RegExp(
          r'\bheight\s*(?:is|=|to)?\s*(\d+)\s*(?:cm|centimeters?)?\b',
          caseSensitive: false,
        ).firstMatch(userInput);
    if (heightMatch != null) {
      final height = heightMatch.group(1)!;
      final entry = MemoryEntry(
        key: 'height',
        value: '$height cm',
        category: 'health',
        importance: 4,
        source: 'user_input',
      );
      await _saveMemory(entry);
      await _upsertUserProfilePatch({'height': double.tryParse(height)});
      Logger.d('MemoryService', 'Auto-extracted height: $height cm');
    }

    // Age: "我28岁" / "年龄改成29"
    final ageMatch =
        RegExp(
          r'(?:我|年龄)\w*(?:是|改成|改为|设为)?\s*(\d+)\s*岁?',
        ).firstMatch(userInput) ??
        RegExp(
          r'\bage\s*(?:is|=|to)?\s*(\d+)\b',
          caseSensitive: false,
        ).firstMatch(userInput);
    if (ageMatch != null) {
      final age = ageMatch.group(1)!;
      final entry = MemoryEntry(
        key: 'age',
        value: '$age 岁',
        category: 'health',
        importance: 4,
        source: 'user_input',
      );
      await _saveMemory(entry);
      await _upsertUserProfilePatch({'age': int.tryParse(age)});
      Logger.d('MemoryService', 'Auto-extracted age: $age');
    }

    // Disease/condition: "我有XX炎", "我有XX病", "XX受过伤"
    final diseaseRegex = RegExp(r'我有[了]?([一-鿿]{2,}(?:炎|病|突出|伤|不适|问题))');
    if (diseaseRegex.hasMatch(userInput)) {
      final condition = diseaseRegex.firstMatch(userInput)!.group(1)!;
      final entry = MemoryEntry(
        key: 'condition_$condition',
        value: condition,
        category: 'health',
        importance: 5,
        source: 'user_input',
      );
      await _saveMemory(entry);
      await _mergeUserProfileCondition(condition);
      Logger.d('MemoryService', 'Auto-extracted condition: $condition');
    }

    // Goal: "我要增肌/减脂/减肥/增重/保持健康/力量提升"
    final goalMatch =
        RegExp(r'我要(增肌|减脂|减肥|增重|保持健康|力量提升|塑形|增强耐力)').firstMatch(userInput) ??
        RegExp(
          r'\b(?:goal|target)\s*(?:is|=|to)?\s*(fat loss|lose fat|weight loss|muscle gain|strength|health|endurance)\b',
          caseSensitive: false,
        ).firstMatch(userInput);
    if (goalMatch != null) {
      final goal = _normalizeGoal(goalMatch.group(1)!);
      final entry = MemoryEntry(
        key: 'fitness_goal',
        value: goal,
        category: 'fitness',
        importance: 5,
        source: 'user_input',
      );
      await _saveMemory(entry);
      await _upsertUserProfilePatch({'goal': goal});
      Logger.d('MemoryService', 'Auto-extracted goal: $goal');
    }
  }

  // ---------------------------------------------------------------------------
  // Conversation summarization
  // ---------------------------------------------------------------------------

  /// Determine whether a summary should be triggered.
  bool shouldTriggerSummary(int messageCount, Duration sessionDuration) {
    // Trigger at 30 messages
    if (messageCount >= 30) return true;
    // Trigger at 30 minutes
    if (sessionDuration.inMinutes >= 30) return true;
    return false;
  }

  /// Reset session tracking (call when a new session starts).
  void resetSessionTracking() {
    _sessionStartTime = DateTime.now();
    _sessionMessageCount = 0;
  }

  /// Update internal message count (called from ChatProvider).
  void incrementMessageCount() {
    _sessionMessageCount++;
  }

  /// Check if summarization should trigger based on internal tracking.
  Future<bool> checkAndTriggerSummary() async {
    if (_sessionStartTime == null) return false;
    final duration = DateTime.now().difference(_sessionStartTime!);
    if (shouldTriggerSummary(_sessionMessageCount, duration)) {
      // Reset counters after trigger
      _sessionStartTime = DateTime.now();
      _sessionMessageCount = 0;
      return true;
    }
    return false;
  }

  /// Generate a summary of the conversation using LLM.
  Future<void> generateSummary(List<Message> messages) async {
    if (messages.isEmpty) return;
    if (_llmService == null) {
      Logger.w('MemoryService', 'LlmService not available, skipping summary');
      return;
    }

    try {
      // Format conversation for summarization
      final conversationText = messages
          .map((m) => '${m.isUser ? "用户" : "助手"}：${m.content}')
          .join('\n');

      // Truncate if too long (roughly 4000 chars)
      final truncated = conversationText.length > 4000
          ? conversationText.substring(conversationText.length - 4000)
          : conversationText;

      final prompt =
          '请总结以下对话的核心内容，提取关键信息（用户目标、健康状况、偏好等），'
          '以及对话涉及的主题标签（用逗号分隔）。'
          '格式：\n总结：<总结内容>\n主题：<主题1>,<主题2>\n情绪：<情绪标签>\n'
          '对话内容：\n$truncated';

      final summaryText = await _llmService.sendMessageSync(
        messages: [
          {'role': 'user', 'content': prompt},
        ],
        systemPrompt: '你是一个专业的对话总结助手，请简洁准确地总结对话。',
      );

      if (summaryText.isEmpty) return;

      // Parse summary
      final startTime = messages.first.createdAt.toIso8601String();
      final endTime = messages.last.createdAt.toIso8601String();

      String summary = summaryText;
      String topics = '';
      String emotions = '';

      // Extract summary after "总结："
      final summaryMatch = RegExp(
        r'总结[：:](.*?)(?:\n|$)',
      ).firstMatch(summaryText);
      if (summaryMatch != null) {
        summary = summaryMatch.group(1)!.trim();
      }

      // Extract topics after "主题："
      final topicsMatch = RegExp(
        r'主题[：:](.*?)(?:\n|$)',
      ).firstMatch(summaryText);
      if (topicsMatch != null) {
        topics = topicsMatch.group(1)!.trim();
      }

      // Extract emotions after "情绪："
      final emotionsMatch = RegExp(
        r'情绪[：:](.*?)(?:\n|$)',
      ).firstMatch(summaryText);
      if (emotionsMatch != null) {
        emotions = emotionsMatch.group(1)!.trim();
      }

      final sessionId = messages.first.sessionId;
      final summaryId = await _dbHelper
          .upsertConversationSummaryForSession(sessionId, {
            'summary_text': summary,
            'topics': topics,
            'start_time': startTime,
            'end_time': endTime,
            'message_count': messages.length,
            'emotion_tags': emotions,
          });
      await _ragService.indexConversationSummary(
        id: summaryId,
        docKey: 'conversation_summary:$sessionId',
        sourceId: sessionId,
        summary: summary,
        topics: topics,
        emotions: emotions,
      );

      Logger.d('MemoryService', 'Generated conversation summary');
    } catch (e) {
      Logger.e('MemoryService', 'Failed to generate summary: $e');
    }
  }

  /// Distill the current daily/session conversation into one stable summary
  /// row and one stable RAG document. This is intentionally cheap and local so
  /// it can run after every completed assistant response without adding voice
  /// or chat latency.
  Future<int?> distillSessionToRag(String sessionId) async {
    final messages = await _dbHelper.getMessages(sessionId);
    final digest = ConversationDigest.fromMessages(messages);
    if (digest == null) return null;

    final summaryId = await _dbHelper
        .upsertConversationSummaryForSession(sessionId, {
          'summary_text': digest.summary,
          'topics': digest.topics,
          'start_time': digest.startTime,
          'end_time': digest.endTime,
          'message_count': digest.messageCount,
          'emotion_tags': digest.emotions,
        });
    await _ragService.indexConversationSummary(
      id: summaryId,
      docKey: 'conversation_summary:$sessionId',
      sourceId: sessionId,
      summary: digest.summary,
      topics: digest.topics,
      emotions: digest.emotions,
    );
    return summaryId;
  }

  /// Build the short-term message window for a voice turn. Voice and keyboard
  /// chat share the same daily session history so follow-up questions can use
  /// recent context instead of becoming isolated one-shot prompts.
  Future<List<Map<String, String>>> buildApiMessagesForSession({
    required String sessionId,
    required String pendingUserText,
    int limit = 16,
  }) async {
    final history = await _dbHelper.getMessages(sessionId);
    final nonEmptyHistory = history
        .where((message) => message.content.trim().isNotEmpty)
        .toList();
    final historyLimit = limit > 1 ? limit - 1 : 0;
    final window = historyLimit == 0
        ? <Message>[]
        : _takeLast(nonEmptyHistory, historyLimit);

    return [
      ...window.map(
        (message) => {'role': message.role, 'content': message.content},
      ),
      if (pendingUserText.trim().isNotEmpty)
        {'role': 'user', 'content': pendingUserText.trim()},
    ];
  }

  /// Persist a completed voice turn into the same conversation, RAG, and memory
  /// lifecycle used by keyboard chat.
  Future<List<Message>> persistVoiceTurn({
    required String sessionId,
    required String userText,
    required String assistantRawContent,
    bool extractUserMemory = true,
  }) async {
    final trimmedUserText = userText.trim();
    final sanitizedAssistant = LlmService.sanitizeAssistantContent(
      assistantRawContent,
    );
    if (trimmedUserText.isEmpty && sanitizedAssistant.isEmpty) {
      return const [];
    }

    final savedMessages = <Message>[];

    if (trimmedUserText.isNotEmpty) {
      final userMessage = Message(
        sessionId: sessionId,
        role: 'user',
        content: trimmedUserText,
      );
      final userId = await _dbHelper.insertMessage(userMessage);
      final savedUser = userMessage.copyWith(id: userId);
      savedMessages.add(savedUser);
      await indexMessage(savedUser);
      if (extractUserMemory) {
        await extractFromUserInput(trimmedUserText);
      }
    }

    if (sanitizedAssistant.isNotEmpty) {
      final assistantMessage = Message(
        sessionId: sessionId,
        role: 'assistant',
        content: sanitizedAssistant,
      );
      final assistantId = await _dbHelper.insertMessage(assistantMessage);
      final savedAssistant = assistantMessage.copyWith(id: assistantId);
      savedMessages.add(savedAssistant);
      await indexMessage(savedAssistant);
    }

    await processAiResponse(assistantRawContent);
    await distillSessionToRag(sessionId);
    return savedMessages;
  }

  // ---------------------------------------------------------------------------
  // Memory decay
  // ---------------------------------------------------------------------------

  /// Decay memories: reduce importance for unconfirmed entries after 2 weeks.
  /// Memories whose importance drops to 0 are marked as expired.
  Future<void> decayMemories() async {
    try {
      final db = await _dbHelper.database;
      final twoWeeksAgo = DateTime.now()
          .subtract(const Duration(days: 14))
          .toIso8601String();

      // Find memories not confirmed in 2 weeks with importance > 0
      final staleMemories = await db.query(
        'memories',
        where:
            'last_confirmed_at IS NULL AND created_at < ? AND importance > 0',
        whereArgs: [twoWeeksAgo],
      );

      for (final row in staleMemories) {
        final id = row['id'] as int;
        final currentImportance = row['importance'] as int? ?? 1;
        final newImportance = currentImportance - 1;

        if (newImportance <= 0) {
          // Mark as expired
          await db.update(
            'memories',
            {'importance': 0, 'expires_at': DateTime.now().toIso8601String()},
            where: 'id = ?',
            whereArgs: [id],
          );
          Logger.d('MemoryService', 'Expired memory id=$id');
        } else {
          await db.update(
            'memories',
            {'importance': newImportance},
            where: 'id = ?',
            whereArgs: [id],
          );
          Logger.d(
            'MemoryService',
            'Decayed memory id=$id to importance=$newImportance',
          );
        }
      }
    } catch (e) {
      Logger.e('MemoryService', 'Memory decay error: $e');
    }
  }

  List<Message> _takeLast(List<Message> messages, int count) {
    if (messages.length <= count) return messages;
    return messages.sublist(messages.length - count);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  Future<String?> _getUserProfile() async {
    try {
      final db = await _dbHelper.database;
      final prefRows = await db.query(
        'user_preferences',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['user_profile'],
        limit: 1,
      );

      Map<String, dynamic>? profile;
      if (prefRows.isNotEmpty) {
        final value = prefRows.first['value'] as String?;
        if (value != null && value.isNotEmpty) {
          profile = jsonDecode(value) as Map<String, dynamic>;
        }
      }

      profile ??= await _dbHelper.getUserProfile();
      if (profile == null) return null;

      final parts = <String>[];
      if (profile['name'] != null) parts.add('姓名：${profile['name']}');
      if (profile['age'] != null) parts.add('${profile['age']}岁');
      if (profile['height'] != null) parts.add('身高：${profile['height']}cm');
      if (profile['weight'] != null) parts.add('体重：${profile['weight']}kg');
      if (profile['goal'] != null) parts.add('目标：${profile['goal']}');
      if (profile['fitnessLevel'] != null || profile['fitness_level'] != null) {
        parts.add(
          '体能水平：${profile['fitnessLevel'] ?? profile['fitness_level']}',
        );
      }
      if (profile['conditions'] != null) {
        parts.add('健康限制：${profile['conditions']}');
      }
      if (profile['userPortrait'] != null) {
        parts.add('用户画像：${profile['userPortrait']}');
      }
      if (profile['customInfo'] != null) {
        parts.add('补充信息：${profile['customInfo']}');
      }

      return parts.isNotEmpty ? parts.join('，') : null;
    } catch (e) {
      Logger.e('MemoryService', 'Get user profile error: $e');
      return null;
    }
  }

  Future<List<MemoryEntry>> _getImportantFacts() async {
    try {
      return await _dbHelper.getImportantFacts(4);
    } catch (e) {
      Logger.e('MemoryService', 'Get important facts error: $e');
      return [];
    }
  }

  Future<List<MemoryEntry>> _getRecentFacts(int limit) async {
    try {
      // Get recent facts ordered by importance desc, then by created desc
      final all = await _dbHelper.getMemories(limit: limit);
      all.sort((a, b) {
        final impCmp = b.importance.compareTo(a.importance);
        if (impCmp != 0) return impCmp;
        return b.createdAt.compareTo(a.createdAt);
      });
      return all;
    } catch (e) {
      Logger.e('MemoryService', 'Get recent facts error: $e');
      return [];
    }
  }

  Future<List<MemoryEntry>> _getRelevantFacts(
    String? query, {
    int limit = 12,
  }) async {
    final normalized = query?.trim();
    if (normalized == null || normalized.isEmpty) return [];

    try {
      final facts = await _dbHelper.getMemories(limit: 100);
      final terms = _queryTerms(normalized);
      if (terms.isEmpty) return [];

      final scored = <({MemoryEntry fact, int score})>[];
      for (final fact in facts) {
        final haystack = '${fact.key} ${fact.value} ${fact.category}'
            .toLowerCase();
        var score = 0;
        for (final term in terms) {
          if (haystack.contains(term)) score += 2;
        }
        if (score > 0) {
          score += fact.importance;
          scored.add((fact: fact, score: score));
        }
      }

      scored.sort((a, b) {
        final scoreCompare = b.score.compareTo(a.score);
        if (scoreCompare != 0) return scoreCompare;
        return b.fact.createdAt.compareTo(a.fact.createdAt);
      });
      return scored.take(limit).map((s) => s.fact).toList();
    } catch (e) {
      Logger.e('MemoryService', 'Get relevant facts error: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>> _loadUserProfilePrefs() async {
    final db = await _dbHelper.database;
    final prefRows = await db.query(
      'user_preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['user_profile'],
      limit: 1,
    );
    if (prefRows.isEmpty) return <String, dynamic>{};

    final value = prefRows.first['value'] as String?;
    if (value == null || value.isEmpty) return <String, dynamic>{};

    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (e) {
      Logger.e('MemoryService', 'Invalid user_profile preference json: $e');
      return <String, dynamic>{};
    }
  }

  Future<void> _upsertUserProfilePatch(Map<String, dynamic> patch) async {
    final cleanPatch = Map<String, dynamic>.from(patch)
      ..removeWhere((_, value) => value == null || value == '');
    if (cleanPatch.isEmpty) return;

    final db = await _dbHelper.database;
    final profile = await _loadUserProfilePrefs();
    profile.addAll(cleanPatch);
    await db.insert('user_preferences', {
      'key': 'user_profile',
      'value': jsonEncode(profile),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await _ragService.indexUserProfile(profile);
  }

  Future<void> _mergeUserProfileCondition(String condition) async {
    final profile = await _loadUserProfilePrefs();
    final existing = profile['conditions']?.toString().trim();
    final parts = <String>{
      if (existing != null && existing.isNotEmpty)
        ...existing.split(RegExp(r'[、,，;；]\s*')).where((p) => p.isNotEmpty),
      condition,
    };
    await _upsertUserProfilePatch({'conditions': parts.join('、')});
  }

  String _normalizeGoal(String goal) {
    final normalized = goal.trim().toLowerCase();
    return switch (normalized) {
      'fat loss' || 'lose fat' || 'weight loss' => '减脂',
      'muscle gain' => '增肌',
      'strength' => '力量提升',
      'health' => '保持健康',
      'endurance' => '增强耐力',
      _ => goal.trim(),
    };
  }

  Future<int> _saveMemory(MemoryEntry entry) async {
    final route = _memoryPolicy.route(
      key: entry.key,
      value: entry.value,
      category: entry.category,
      importance: entry.importance,
    );
    final routedEntry = entry.copyWith(
      category: route.category,
      importance: route.normalizedImportance,
    );
    final id = await _dbHelper.insertMemory(routedEntry);
    final savedEntry = routedEntry.copyWith(id: id);

    if (route.profilePatch.isNotEmpty) {
      final conditions = route.profilePatch['conditions'];
      if (conditions is String && conditions.trim().isNotEmpty) {
        await _mergeUserProfileCondition(conditions);
      } else {
        await _upsertUserProfilePatch(route.profilePatch);
      }
    }

    if (route.indexInRag) {
      await _ragService.indexMemory(savedEntry);
    }
    return id;
  }

  Future<void> indexMessage(Message message) async {
    await _ragService.indexMessage(message);
  }

  Future<void> indexRecentWorkouts({int limit = 20}) async {
    await _ragService.indexRecentWorkouts(limit: limit);
  }

  List<String> _queryTerms(String query) {
    final lower = query.toLowerCase();
    final terms = <String>{};
    for (final match in RegExp(r'[a-zA-Z0-9_]+').allMatches(lower)) {
      final term = match.group(0);
      if (term != null && term.length >= 2) terms.add(term);
    }
    for (final match in RegExp(r'[\u4e00-\u9fff]{2,}').allMatches(query)) {
      final text = match.group(0);
      if (text == null) continue;
      terms.add(text);
      for (var i = 0; i < text.length - 1; i++) {
        terms.add(text.substring(i, i + 2));
      }
    }
    return terms.toList();
  }

  Future<List<Map<String, dynamic>>> _getRecentSummaries(int limit) async {
    try {
      return await _dbHelper.getRecentSummaries(limit);
    } catch (e) {
      Logger.e('MemoryService', 'Get recent summaries error: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _getRecentWorkouts(int limit) async {
    try {
      return await _dbHelper.getRecentWorkouts(limit);
    } catch (e) {
      Logger.e('MemoryService', 'Get recent workouts error: $e');
      return [];
    }
  }

  Future<List<String>> _getWorkoutSetDetails(int workoutId) async {
    try {
      final db = await _dbHelper.database;
      final rows = await db.rawQuery(
        '''
        SELECT s.exercise_id, e.name as exercise_name, s.set_number, s.weight_kg, s.reps, s.is_completed
        FROM training_sets s
        LEFT JOIN exercises e ON s.exercise_id = e.id
        WHERE s.workout_id = ?
        ORDER BY s.exercise_id ASC, s.set_number ASC
        ''',
        [workoutId],
      );
      return rows.map((row) {
        final name =
            row['exercise_name']?.toString() ?? '动作#${row['exercise_id']}';
        final setNumber = row['set_number'] ?? '';
        final weight = (row['weight_kg'] as num?)?.toDouble() ?? 0;
        final reps = row['reps'] ?? 0;
        final completed = row['is_completed'] == 1 ? '已完成' : '未完成';
        return '$name 第$setNumber组 ${weight.toStringAsFixed(weight.truncateToDouble() == weight ? 0 : 1)}kg x $reps ($completed)';
      }).toList();
    } catch (e) {
      Logger.e('MemoryService', 'Get workout set details error: $e');
      return [];
    }
  }
}

class ConversationDigest {
  final String summary;
  final String topics;
  final String emotions;
  final String startTime;
  final String endTime;
  final int messageCount;

  const ConversationDigest({
    required this.summary,
    required this.topics,
    required this.emotions,
    required this.startTime,
    required this.endTime,
    required this.messageCount,
  });

  static ConversationDigest? fromMessages(List<Message> messages) {
    final meaningful = messages
        .where((message) => message.content.trim().isNotEmpty)
        .toList();
    if (meaningful.isEmpty) return null;

    final recent = meaningful.length > 8
        ? meaningful.sublist(meaningful.length - 8)
        : meaningful;
    final lines = recent
        .map((message) {
          final label = message.isUser ? '用户' : '助手';
          return '$label：${_compact(message.content)}';
        })
        .join(' / ');
    final topics = _extractTopics(meaningful);

    return ConversationDigest(
      summary: '最近对话摘要：$lines',
      topics: topics,
      emotions: 'neutral',
      startTime: meaningful.first.createdAt.toIso8601String(),
      endTime: meaningful.last.createdAt.toIso8601String(),
      messageCount: meaningful.length,
    );
  }

  static String _compact(String text) {
    final normalized = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.length <= 120) return normalized;
    return '${normalized.substring(0, 120)}...';
  }

  static String _extractTopics(List<Message> messages) {
    final text = messages.map((message) => message.content).join('\n');
    final topics = <String>{};
    final rules = <String, List<String>>{
      '用户档案': ['身高', '体重', '年龄', '姓名'],
      '训练': ['训练', '卧推', '深蹲', '硬拉', '组', 'kg', '公斤'],
      '目标': ['目标', '减脂', '增肌', '力量', '塑形', '耐力'],
      '健康限制': ['伤', '病', '痛', '不适', '过敏', '禁忌'],
      '偏好': ['喜欢', '偏好', '不喜欢', '避免'],
    };

    for (final entry in rules.entries) {
      if (entry.value.any(text.contains)) {
        topics.add(entry.key);
      }
    }

    return topics.isEmpty ? '日常对话' : topics.join(',');
  }
}
