class Profession {
  final String id;
  final String name;
  final String field;
  final bool enabled;
  final bool isCustom;

  const Profession({
    required this.id,
    required this.name,
    required this.field,
    this.enabled = true,
    this.isCustom = false,
  });

  static List<Profession> get defaultProfessions => [
    Profession(id: 'fitness', name: '世界顶级健身教练', field: '训练计划、动作技术、增肌减脂、力量训练'),
    Profession(id: 'nutritionist', name: '世界顶级营养学家', field: '饮食方案、补剂建议、热量计算'),
    Profession(id: 'dietitian', name: '世界顶级营养师', field: '食材搭配、膳食结构、特殊饮食定制'),
    Profession(
      id: 'longevity',
      name: '世界顶级健康长寿专家',
      field: '抗衰老、睡眠、压力管理、生物年龄优化',
    ),
    Profession(id: 'rehab', name: '世界顶级康复训练师', field: '运动损伤预防、疼痛处理、术后恢复、姿势纠正'),
  ];

  Profession copyWith({bool? enabled}) => Profession(
    id: id,
    name: name,
    field: field,
    enabled: enabled ?? this.enabled,
    isCustom: isCustom,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'field': field,
    'enabled': enabled,
    'isCustom': isCustom,
  };

  factory Profession.fromJson(Map<String, dynamic> json) => Profession(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    field: json['field'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    isCustom: json['isCustom'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Profession &&
          id == other.id &&
          name == other.name &&
          field == other.field &&
          enabled == other.enabled &&
          isCustom == other.isCustom;

  @override
  int get hashCode => Object.hash(id, name, field, enabled, isCustom);
}
