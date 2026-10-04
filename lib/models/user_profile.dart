class UserProfile {
  final String? name;
  final int? age;
  final double? height;
  final double? weight;
  final String? fitnessLevel;
  final String? goal;
  final String? conditions;
  final String? userPortrait;
  final String? customInfo;

  const UserProfile({
    this.name,
    this.age,
    this.height,
    this.weight,
    this.fitnessLevel,
    this.goal,
    this.conditions,
    this.userPortrait,
    this.customInfo,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'age': age,
    'height': height,
    'weight': weight,
    'fitnessLevel': fitnessLevel,
    'goal': goal,
    'conditions': conditions,
    'userPortrait': userPortrait,
    'customInfo': customInfo,
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    name: json['name'] as String?,
    age: json['age'] as int?,
    height: (json['height'] as num?)?.toDouble(),
    weight: (json['weight'] as num?)?.toDouble(),
    fitnessLevel: json['fitnessLevel'] as String?,
    goal: json['goal'] as String?,
    conditions: json['conditions'] as String?,
    userPortrait: json['userPortrait'] as String?,
    customInfo: json['customInfo'] as String?,
  );

  UserProfile copyWith({
    String? name,
    int? age,
    double? height,
    double? weight,
    String? fitnessLevel,
    String? goal,
    String? conditions,
    String? userPortrait,
    String? customInfo,
  }) => UserProfile(
    name: name ?? this.name,
    age: age ?? this.age,
    height: height ?? this.height,
    weight: weight ?? this.weight,
    fitnessLevel: fitnessLevel ?? this.fitnessLevel,
    goal: goal ?? this.goal,
    conditions: conditions ?? this.conditions,
    userPortrait: userPortrait ?? this.userPortrait,
    customInfo: customInfo ?? this.customInfo,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserProfile &&
          name == other.name &&
          age == other.age &&
          height == other.height &&
          weight == other.weight &&
          fitnessLevel == other.fitnessLevel &&
          goal == other.goal &&
          conditions == other.conditions &&
          userPortrait == other.userPortrait &&
          customInfo == other.customInfo;

  @override
  int get hashCode => Object.hash(
    name,
    age,
    height,
    weight,
    fitnessLevel,
    goal,
    conditions,
    userPortrait,
    customInfo,
  );
}
