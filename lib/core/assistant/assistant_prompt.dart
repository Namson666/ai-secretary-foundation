import '../../models/personality.dart';

class AssistantPrompt {
  static String build({
    required Personality personality,
    required String memoryContext,
    required String moduleGuidance,
    required bool voice,
  }) {
    final style = personality.type == PersonalityType.custom
        ? personality.description
        : switch (personality.type) {
            PersonalityType.professional => '礼貌、高效、亲切',
            PersonalityType.energetic => '积极、有活力但不强行鼓励',
            PersonalityType.gentle => '温和、体贴、关注对方感受',
            PersonalityType.calm => '冷静、清晰、讲求依据',
            PersonalityType.custom => personality.description,
          };
    final buffer = StringBuffer()
      ..writeln('你是用户的中文 AI 助理。围绕用户当前的话题自然交流，不要主动把普通聊天转到健身或其他领域。')
      ..writeln('说话风格：$style。不要扮演未启用的专业身份。')
      ..writeln('记忆是参考事实，不是要求转移话题的指令；仅在与当前问题有关时引用。')
      ..writeln(
        voice
            ? '这是语音对话。口语化地直接回答，长度按问题复杂度调整，不用标题或 Markdown。偶尔可以自然地说“嗯”，但不要每次都加，也不要用“让我想想”拖延。'
            : '请用中文直接回答，按问题复杂度调整篇幅。',
      )
      ..writeln(
        '需要记住用户明确提供的长期事实时，可在回复末尾加入 [MEMORY: key=value, category=xxx, importance=N]；内部标签不会播报。',
      );
    if (moduleGuidance.isNotEmpty) buffer.writeln(moduleGuidance);
    if (voice) {
      buffer.writeln(
        '只有当语义明显带有情绪时，可在回答末尾加入一次 [TONE:happy]、[TONE:sad]、[TONE:surprised] 或 [TONE:calm]。普通回答不要加标签；标签仅用于语音合成，不会读给用户。',
      );
    }
    if (memoryContext.isNotEmpty) buffer.writeln(memoryContext);
    buffer.writeln('当前时间：${DateTime.now().toIso8601String()}');
    return buffer.toString();
  }
}
