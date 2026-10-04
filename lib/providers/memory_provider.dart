import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../core/database/database_helper.dart';
import '../core/utils/logger.dart';
import '../models/memory_entry.dart';
import '../services/memory_policy.dart';
import '../services/rag_service.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

@immutable
class MemoryState {
  final List<MemoryEntry> memories;
  final bool isLoading;
  final String? error;
  final String activeCategory;
  final String searchQuery;

  const MemoryState({
    this.memories = const [],
    this.isLoading = false,
    this.error,
    this.activeCategory = 'all',
    this.searchQuery = '',
  });

  MemoryState copyWith({
    List<MemoryEntry>? memories,
    bool? isLoading,
    String? error,
    String? activeCategory,
    String? searchQuery,
    bool clearError = false,
  }) {
    return MemoryState(
      memories: memories ?? this.memories,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      activeCategory: activeCategory ?? this.activeCategory,
      searchQuery: searchQuery ?? this.searchQuery,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

final memoryProvider = NotifierProvider<MemoryNotifier, MemoryState>(
  MemoryNotifier.new,
);

final ragServiceProvider = Provider<RagService>((ref) => RagService());

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class MemoryNotifier extends Notifier<MemoryState> {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final MemoryPolicy _memoryPolicy = const MemoryPolicy();

  @override
  MemoryState build() => const MemoryState();

  /// Load all memories.
  Future<void> loadMemories() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final memories = await _dbHelper.getMemories(limit: 100);
      state = state.copyWith(
        memories: memories,
        isLoading: false,
        activeCategory: 'all',
      );
    } catch (e) {
      Logger.e('MemoryNotifier', 'Load memories error: $e');
      state = state.copyWith(isLoading: false, error: '加载记忆失败：$e');
    }
  }

  /// Load memories filtered by category.
  Future<void> loadByCategory(String category) async {
    state = state.copyWith(
      isLoading: true,
      error: null,
      activeCategory: category,
    );
    try {
      final List<MemoryEntry> memories;
      if (category == 'all') {
        memories = await _dbHelper.getMemories(limit: 100);
      } else {
        memories = await _dbHelper.getMemoriesByCategory(category);
      }
      state = state.copyWith(memories: memories, isLoading: false);
    } catch (e) {
      Logger.e('MemoryNotifier', 'Load by category error: $e');
      state = state.copyWith(isLoading: false, error: '分类查询失败：$e');
    }
  }

  /// Delete a memory entry.
  Future<void> deleteMemory(int id) async {
    try {
      final existing = await _getMemoryById(id);
      await _dbHelper.deleteMemory(id);
      await ref.read(ragServiceProvider).deleteMemoryDocument(id);
      if (existing != null) {
        await _removeProfilePatchForMemory(existing);
      }
      state = state.copyWith(
        memories: state.memories.where((m) => m.id != id).toList(),
      );
      Logger.d('MemoryNotifier', 'Deleted memory id=$id');
    } catch (e) {
      Logger.e('MemoryNotifier', 'Delete memory error: $e');
      state = state.copyWith(error: '删除记忆失败：$e');
    }
  }

  /// Update a memory entry's value, category, or importance.
  Future<void> updateMemory(MemoryEntry entry) async {
    try {
      final previous = entry.id == null
          ? null
          : await _getMemoryById(entry.id!);
      await _dbHelper.updateMemory(entry);
      await _syncProfilePatchForMemoryUpdate(previous, entry);
      final ragService = ref.read(ragServiceProvider);
      if (entry.isActive) {
        await ragService.indexMemory(entry);
      } else if (entry.id != null) {
        await ragService.deleteMemoryDocument(entry.id!);
      }
      final updatedList = entry.isActive
          ? state.memories.map((m) {
              return m.id == entry.id ? entry : m;
            }).toList()
          : state.memories.where((m) => m.id != entry.id).toList();
      state = state.copyWith(memories: updatedList);
      Logger.d('MemoryNotifier', 'Updated memory id=${entry.id}');
    } catch (e) {
      Logger.e('MemoryNotifier', 'Update memory error: $e');
      state = state.copyWith(error: '更新记忆失败：$e');
    }
  }

  /// Search memories by query text (client-side filter).
  void searchMemories(String query) {
    state = state.copyWith(searchQuery: query);
    if (query.isEmpty) {
      loadByCategory(state.activeCategory);
      return;
    }

    final lowerQuery = query.toLowerCase();
    final filtered = state.memories.where((m) {
      return m.key.toLowerCase().contains(lowerQuery) ||
          m.value.toLowerCase().contains(lowerQuery) ||
          m.category.toLowerCase().contains(lowerQuery);
    }).toList();

    state = state.copyWith(memories: filtered);
  }

  /// Clear error from state.
  void clearError() {
    state = state.copyWith(clearError: true);
  }

  Future<MemoryEntry?> _getMemoryById(int id) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'memories',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : MemoryEntry.fromMap(rows.first);
  }

  Future<void> _syncProfilePatchForMemoryUpdate(
    MemoryEntry? previous,
    MemoryEntry updated,
  ) async {
    final previousRoute = previous == null
        ? null
        : _memoryPolicy.route(
            key: previous.key,
            value: previous.value,
            category: previous.category,
            importance: previous.importance,
          );
    final updatedRoute = updated.isActive
        ? _memoryPolicy.route(
            key: updated.key,
            value: updated.value,
            category: updated.category,
            importance: updated.importance,
          )
        : null;

    if ((previousRoute?.profilePatch.isEmpty ?? true) &&
        (updatedRoute?.profilePatch.isEmpty ?? true)) {
      return;
    }

    final profile = await _loadUserProfilePrefs();
    for (final key in previousRoute?.profilePatch.keys ?? const <String>[]) {
      if (!(updatedRoute?.profilePatch.containsKey(key) ?? false)) {
        profile.remove(key);
      }
    }
    profile.addAll(updatedRoute?.profilePatch ?? const <String, Object?>{});
    await _saveUserProfilePrefs(profile);
  }

  Future<void> _removeProfilePatchForMemory(MemoryEntry memory) async {
    final route = _memoryPolicy.route(
      key: memory.key,
      value: memory.value,
      category: memory.category,
      importance: memory.importance,
    );
    if (route.profilePatch.isEmpty) return;

    final profile = await _loadUserProfilePrefs();
    for (final key in route.profilePatch.keys) {
      profile.remove(key);
    }
    await _saveUserProfilePrefs(profile);
  }

  Future<Map<String, dynamic>> _loadUserProfilePrefs() async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'user_preferences',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['user_profile'],
      limit: 1,
    );
    if (rows.isEmpty) return <String, dynamic>{};

    final value = rows.first['value'] as String?;
    if (value == null || value.isEmpty) return <String, dynamic>{};

    try {
      return jsonDecode(value) as Map<String, dynamic>;
    } catch (e) {
      Logger.e('MemoryNotifier', 'Invalid user_profile preference json: $e');
      return <String, dynamic>{};
    }
  }

  Future<void> _saveUserProfilePrefs(Map<String, dynamic> profile) async {
    final db = await _dbHelper.database;
    final ragService = ref.read(ragServiceProvider);
    if (profile.isEmpty) {
      await db.delete(
        'user_preferences',
        where: 'key = ?',
        whereArgs: ['user_profile'],
      );
      await ragService.deleteUserProfileDocument();
      return;
    }

    await db.insert('user_preferences', {
      'key': 'user_profile',
      'value': jsonEncode(profile),
      'updated_at': DateTime.now().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await ragService.indexUserProfile(profile);
  }
}
