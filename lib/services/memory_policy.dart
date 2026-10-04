class MemoryPolicy {
  const MemoryPolicy();

  MemoryRouting route({
    required String key,
    required String value,
    String category = 'life',
    int importance = 3,
  }) {
    final normalizedKey = key.trim().toLowerCase();
    final normalizedCategory = category.trim().toLowerCase();
    final profileField = _profileFieldFor(normalizedKey);
    final profileValue = _coerceProfileValue(profileField, value);
    final shouldLoadEveryPrompt =
        profileField != null ||
        importance >= 5 ||
        _alwaysLoadKeys.any(normalizedKey.contains) ||
        _alwaysLoadCategories.contains(normalizedCategory);

    return MemoryRouting(
      target: profileField != null
          ? MemoryStorageTarget.userProfile
          : shouldLoadEveryPrompt
          ? MemoryStorageTarget.coreMemory
          : MemoryStorageTarget.longTermMemory,
      profilePatch: profileField == null
          ? const {}
          : {profileField: profileValue},
      normalizedImportance: shouldLoadEveryPrompt && importance < 4
          ? 4
          : importance.clamp(1, 5),
      category: profileField != null
          ? _categoryForProfileField(profileField)
          : category,
      loadEveryPrompt: shouldLoadEveryPrompt,
      indexInRag: true,
    );
  }

  String? _profileFieldFor(String key) {
    if (key == 'name' || key == '姓名') return 'name';
    if (key == 'age' || key == '年龄') return 'age';
    if (key == 'height' || key == '身高') return 'height';
    if (key == 'weight' || key == '体重') return 'weight';
    if (key == 'goal' || key == 'fitness_goal' || key == '目标') return 'goal';
    if (key == 'fitness_level' || key == 'fitnesslevel' || key == '训练水平') {
      return 'fitnessLevel';
    }
    if (key == 'conditions' ||
        key == 'condition' ||
        key.startsWith('condition_') ||
        key.contains('injury') ||
        key.contains('伤病') ||
        key.contains('健康限制')) {
      return 'conditions';
    }
    if (key == 'user_portrait' || key == 'userportrait' || key == '用户画像') {
      return 'userPortrait';
    }
    if (key == 'custom_info' || key == 'custominfo' || key == '补充信息') {
      return 'customInfo';
    }
    return null;
  }

  Object? _coerceProfileValue(String? field, String value) {
    final trimmed = value.trim();
    if (field == 'age') {
      return int.tryParse(trimmed) ??
          int.tryParse(_firstNumber(trimmed)) ??
          trimmed;
    }
    if (field == 'height' || field == 'weight') {
      return double.tryParse(trimmed) ??
          double.tryParse(_firstNumber(trimmed)) ??
          trimmed;
    }
    return trimmed;
  }

  String _firstNumber(String text) {
    return RegExp(r'\d+(?:\.\d+)?').firstMatch(text)?.group(0) ?? '';
  }

  String _categoryForProfileField(String field) {
    return switch (field) {
      'height' || 'weight' || 'age' || 'conditions' => 'health',
      'goal' || 'fitnessLevel' => 'fitness',
      _ => 'life',
    };
  }

  static const _alwaysLoadCategories = {
    'health',
    'fitness',
    'preference',
    'safety',
  };

  static const _alwaysLoadKeys = {
    'allergy',
    'medication',
    'injury',
    'condition',
    'preference',
    'avoid',
    '过敏',
    '用药',
    '伤',
    '病',
    '偏好',
    '禁忌',
  };
}

enum MemoryStorageTarget { userProfile, coreMemory, longTermMemory, ragOnly }

class MemoryRouting {
  final MemoryStorageTarget target;
  final Map<String, Object?> profilePatch;
  final int normalizedImportance;
  final String category;
  final bool loadEveryPrompt;
  final bool indexInRag;

  const MemoryRouting({
    required this.target,
    required this.profilePatch,
    required this.normalizedImportance,
    required this.category,
    required this.loadEveryPrompt,
    required this.indexInRag,
  });
}
