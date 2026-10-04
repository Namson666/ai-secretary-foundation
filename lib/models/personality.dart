enum PersonalityType { professional, energetic, gentle, calm, custom }

class Personality {
  final PersonalityType type;
  final String name;
  final String description;
  final bool isCustom;

  const Personality({
    required this.type,
    required this.name,
    required this.description,
    this.isCustom = false,
  });

  static List<Personality> get presets => [
    Personality(
      type: PersonalityType.professional,
      name: '专业助理',
      description: '礼貌、高效、亲切，保持职业距离感',
    ),
    Personality(
      type: PersonalityType.energetic,
      name: '活力伙伴',
      description: '充满激情、善于鼓励、训练时喊"再来一组！"',
    ),
    Personality(
      type: PersonalityType.gentle,
      name: '温柔陪伴',
      description: '细心体贴、关注感受、适合疲劳恢复期',
    ),
    Personality(
      type: PersonalityType.calm,
      name: '冷静导师',
      description: '理性、数据驱动、善于分析问题和制定计划',
    ),
  ];

  Personality copyWith({String? customDesc}) {
    if (type == PersonalityType.custom) {
      return Personality(
        type: type,
        name: name,
        description: customDesc ?? description,
        isCustom: true,
      );
    }
    return this;
  }

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'name': name,
    'description': description,
    'isCustom': isCustom,
  };

  factory Personality.fromJson(Map<String, dynamic> json) {
    final type = PersonalityType.values.firstWhere(
      (e) => e.name == json['type'],
      orElse: () => PersonalityType.professional,
    );
    return Personality(
      type: type,
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      isCustom: json['isCustom'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Personality &&
          type == other.type &&
          name == other.name &&
          description == other.description &&
          isCustom == other.isCustom;

  @override
  int get hashCode => Object.hash(type, name, description, isCustom);
}
