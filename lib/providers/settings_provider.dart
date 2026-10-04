import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/personality.dart';
import '../models/ai_config.dart';
import '../models/user_profile.dart';
import 'package:sqflite/sqflite.dart';
import '../core/database/database_helper.dart';
import '../core/utils/logger.dart';
import '../core/utils/constants.dart';
import '../services/minimax_voice_catalog.dart';
import '../core/app_edition.dart';

enum AsrEngine { local, aliyunFlash, minimaxFile }

class SettingsState {
  final Personality personality;
  final List<Profession> professions;
  final UserProfile userProfile;
  final String ttsVoiceId;
  final String ttsModel;
  final double ttsSpeed;
  final AsrEngine asrEngine;
  final String llmModel;
  final bool isLoading;

  const SettingsState({
    required this.personality,
    required this.professions,
    required this.userProfile,
    required this.ttsVoiceId,
    required this.ttsModel,
    required this.ttsSpeed,
    required this.asrEngine,
    required this.llmModel,
    this.isLoading = false,
  });

  SettingsState copyWith({
    Personality? personality,
    List<Profession>? professions,
    UserProfile? userProfile,
    String? ttsVoiceId,
    String? ttsModel,
    double? ttsSpeed,
    AsrEngine? asrEngine,
    String? llmModel,
    bool? isLoading,
  }) {
    return SettingsState(
      personality: personality ?? this.personality,
      professions: professions ?? this.professions,
      userProfile: userProfile ?? this.userProfile,
      ttsVoiceId: ttsVoiceId ?? this.ttsVoiceId,
      ttsModel: ttsModel ?? this.ttsModel,
      ttsSpeed: ttsSpeed ?? this.ttsSpeed,
      asrEngine: asrEngine ?? this.asrEngine,
      llmModel: llmModel ?? this.llmModel,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  static const SettingsState initial = SettingsState(
    personality: Personality(
      type: PersonalityType.professional,
      name: '专业助理',
      description: '礼貌、高效、亲切，保持职业距离感',
    ),
    professions: [
      Profession(id: 'fitness', name: '世界顶级健身教练', field: '训练计划、动作技术、增肌减脂、力量训练'),
      Profession(id: 'nutritionist', name: '世界顶级营养学家', field: '饮食方案、补剂建议、热量计算'),
      Profession(id: 'dietitian', name: '世界顶级营养师', field: '食材搭配、膳食结构、特殊饮食定制'),
      Profession(
        id: 'longevity',
        name: '世界顶级健康长寿专家',
        field: '抗衰老、睡眠、压力管理、生物年龄优化',
      ),
      Profession(
        id: 'rehab',
        name: '世界顶级康复训练师',
        field: '运动损伤预防、疼痛处理、术后恢复、姿势纠正',
      ),
    ],
    userProfile: UserProfile(),
    ttsVoiceId: AppConstants.ttsVoice,
    ttsModel: AppConstants.ttsModel,
    ttsSpeed: 1.0,
    asrEngine: AsrEngine.local,
    llmModel: AppConstants.llmModel,
  );

  static const SettingsState foundationInitial = SettingsState(
    personality: Personality(
      type: PersonalityType.professional,
      name: '专业助理',
      description: '礼貌、高效、亲切，保持职业距离感',
    ),
    professions: [],
    userProfile: UserProfile(),
    ttsVoiceId: AppConstants.ttsVoice,
    ttsModel: AppConstants.ttsModel,
    ttsSpeed: 1.0,
    asrEngine: AsrEngine.local,
    llmModel: AppConstants.llmModel,
  );
}

class SettingsNotifier extends Notifier<SettingsState> {
  bool _loadScheduled = false;
  int _voiceChoiceVersion = 0;
  int _ttsModelChoiceVersion = 0;
  int _ttsSpeedChoiceVersion = 0;
  int _asrChoiceVersion = 0;
  int _llmChoiceVersion = 0;

  @override
  SettingsState build() {
    if (!_loadScheduled) {
      _loadScheduled = true;
      Future.microtask(_loadSettings);
    }
    return AppEdition.isFoundation
        ? SettingsState.foundationInitial
        : SettingsState.initial;
  }

  Future<void> _loadSettings() async {
    if (!ref.mounted) return;
    final voiceChoiceVersion = _voiceChoiceVersion;
    final ttsModelChoiceVersion = _ttsModelChoiceVersion;
    final ttsSpeedChoiceVersion = _ttsSpeedChoiceVersion;
    final asrChoiceVersion = _asrChoiceVersion;
    final llmChoiceVersion = _llmChoiceVersion;
    try {
      state = state.copyWith(isLoading: true);
      final db = await DatabaseHelper.instance.database;

      final maps = await db.query('user_preferences');
      if (!ref.mounted) return;
      final prefMap = <String, String>{};
      for (final row in maps) {
        final key = row['key'] as String?;
        final value = row['value'] as String?;
        if (key != null && value != null) {
          prefMap[key] = value;
        }
      }

      if (prefMap.containsKey('personality_type')) {
        final personality = Personality.fromJson(
          jsonDecode(prefMap['personality_type']!) as Map<String, dynamic>,
        );
        state = state.copyWith(personality: personality);
      }

      if (prefMap.containsKey('custom_personality_desc')) {
        // custom desc is embedded in personality json now
      }

      if (!AppEdition.isFoundation && prefMap.containsKey('professions')) {
        final list = jsonDecode(prefMap['professions']!) as List;
        final professions = list
            .map((e) => Profession.fromJson(e as Map<String, dynamic>))
            .toList();
        state = state.copyWith(professions: professions);
      }

      if (prefMap.containsKey('user_profile')) {
        final profile = UserProfile.fromJson(
          jsonDecode(prefMap['user_profile']!) as Map<String, dynamic>,
        );
        state = state.copyWith(userProfile: profile);
      }

      if (voiceChoiceVersion == _voiceChoiceVersion) {
        state = state.copyWith(
          ttsVoiceId: MiniMaxVoiceCatalog.validatedId(prefMap['tts_voice_id']),
        );
      }
      if (ttsModelChoiceVersion == _ttsModelChoiceVersion) {
        final saved = prefMap['tts_model'];
        state = state.copyWith(
          ttsModel: saved != null && AppConstants.ttsChoices.contains(saved)
              ? saved
              : AppConstants.ttsModel,
        );
      }
      if (ttsSpeedChoiceVersion == _ttsSpeedChoiceVersion) {
        final saved = double.tryParse(prefMap['tts_speed'] ?? '');
        if (saved != null && saved.isFinite && saved >= 0.5 && saved <= 2.0) {
          state = state.copyWith(ttsSpeed: saved);
        }
      }
      if (asrChoiceVersion == _asrChoiceVersion) {
        final saved = prefMap['asr_engine'];
        state = state.copyWith(
          asrEngine: AsrEngine.values.firstWhere(
            (engine) => engine.name == saved,
            orElse: () => AsrEngine.local,
          ),
        );
      }
      if (llmChoiceVersion == _llmChoiceVersion) {
        final saved = prefMap['llm_model'];
        state = state.copyWith(
          llmModel: saved != null && AppConstants.llmChoices.contains(saved)
              ? saved
              : AppConstants.llmModel,
        );
      }
    } catch (e) {
      Logger.e('SettingsNotifier', 'Failed to load settings: $e');
    } finally {
      if (ref.mounted) state = state.copyWith(isLoading: false);
    }
  }

  Future<void> _saveToDb() async {
    final snapshot = state;
    try {
      final db = await DatabaseHelper.instance.database;
      final now = DateTime.now().toIso8601String();

      await db.insert('user_preferences', {
        'key': 'personality_type',
        'value': jsonEncode(snapshot.personality.toJson()),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('user_preferences', {
        'key': 'professions',
        'value': jsonEncode(
          snapshot.professions.map((p) => p.toJson()).toList(),
        ),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('user_preferences', {
        'key': 'user_profile',
        'value': jsonEncode(snapshot.userProfile.toJson()),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('user_preferences', {
        'key': 'tts_voice_id',
        'value': snapshot.ttsVoiceId,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('user_preferences', {
        'key': 'tts_model',
        'value': snapshot.ttsModel,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('user_preferences', {
        'key': 'tts_speed',
        'value': snapshot.ttsSpeed.toString(),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('user_preferences', {
        'key': 'asr_engine',
        'value': snapshot.asrEngine.name,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

      await db.insert('user_preferences', {
        'key': 'llm_model',
        'value': snapshot.llmModel,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      Logger.e('SettingsNotifier', 'Failed to save settings: $e');
    }
  }

  void setPersonality(Personality personality) {
    state = state.copyWith(personality: personality);
    _saveToDb();
  }

  void toggleProfession(String professionId) {
    final updated = state.professions.map((p) {
      if (p.id == professionId) {
        return p.copyWith(enabled: !p.enabled);
      }
      return p;
    }).toList();
    state = state.copyWith(professions: updated);
    _saveToDb();
  }

  void addCustomProfession(String name, String field) {
    final newProfession = Profession(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      field: field,
      isCustom: true,
    );
    state = state.copyWith(professions: [...state.professions, newProfession]);
    _saveToDb();
  }

  void removeCustomProfession(String professionId) {
    state = state.copyWith(
      professions: state.professions
          .where((p) => p.id != professionId)
          .toList(),
    );
    _saveToDb();
  }

  void updateUserProfile(UserProfile profile) {
    state = state.copyWith(userProfile: profile);
    _saveToDb();
  }

  Future<void> setTtsVoiceId(String voiceId) async {
    _voiceChoiceVersion++;
    state = state.copyWith(
      ttsVoiceId: MiniMaxVoiceCatalog.validatedId(voiceId),
    );
    await _saveToDb();
  }

  Future<void> setTtsModel(String model) async {
    if (!AppConstants.ttsChoices.contains(model)) {
      throw ArgumentError.value(model, 'model');
    }
    _ttsModelChoiceVersion++;
    state = state.copyWith(ttsModel: model);
    await _saveToDb();
  }

  Future<void> setTtsSpeed(double speed) async {
    if (!speed.isFinite || speed < 0.5 || speed > 2.0) {
      throw ArgumentError.value(speed, 'speed');
    }
    _ttsSpeedChoiceVersion++;
    state = state.copyWith(ttsSpeed: speed);
    await _saveToDb();
  }

  Future<void> setAsrEngine(AsrEngine engine) async {
    _asrChoiceVersion++;
    state = state.copyWith(asrEngine: engine);
    await _saveToDb();
  }

  Future<void> setLlmModel(String model) async {
    if (!AppConstants.llmChoices.contains(model)) {
      throw ArgumentError.value(model, 'model');
    }
    _llmChoiceVersion++;
    state = state.copyWith(llmModel: model);
    await _saveToDb();
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, SettingsState>(
  SettingsNotifier.new,
);
