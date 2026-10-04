/// A domain capability that can be attached to the reusable conversation base.
abstract class AssistantModule {
  String get id;
  String get guidance;
  List<Map<String, dynamic>> get tools;

  bool matches(String userText);

  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
  });

  bool isProposal(String toolName) => false;

  String describeProposal(Map<String, dynamic> proposal) =>
      throw UnsupportedError('Module does not support proposals');

  String? voiceDecision(String userText) => null;

  Future<String> decide(
    int actionId,
    String decision, {
    required String sessionId,
  }) => throw UnsupportedError('Module does not support voice confirmation');

  Future<void> afterAction() async {}

  void afterTool(String name, Map<String, dynamic> result) {}
}

class AssistantModuleRegistry {
  final List<AssistantModule> modules;

  AssistantModuleRegistry(this.modules) {
    final ids = <String>{};
    final names = <String>{};
    for (final module in modules) {
      if (!ids.add(module.id)) throw ArgumentError('Duplicate module ID');
      for (final tool in module.tools) {
        final function = tool['function'] as Map<String, dynamic>;
        if (!names.add(function['name'] as String)) {
          throw ArgumentError('Duplicate assistant tool name');
        }
      }
    }
  }

  List<AssistantModule> select(String userText) => [
    for (final module in modules)
      if (module.matches(userText)) module,
  ];

  static List<Map<String, dynamic>> toolsFor(List<AssistantModule> selected) =>
      [for (final module in selected) ...module.tools];

  static AssistantModule? ownerOf(List<AssistantModule> selected, String name) {
    for (final module in selected) {
      if (module.tools.any(
        (tool) => (tool['function'] as Map<String, dynamic>)['name'] == name,
      )) {
        return module;
      }
    }
    return null;
  }

  static String guidanceFor(List<AssistantModule> selected) => selected
      .map((module) => module.guidance)
      .where((guidance) => guidance.isNotEmpty)
      .join('\n');

  static Future<Map<String, dynamic>> invoke(
    List<AssistantModule> selected,
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
  }) async {
    for (final module in selected) {
      if (module.tools.any(
        (tool) => (tool['function'] as Map<String, dynamic>)['name'] == name,
      )) {
        return module.invoke(name, args, sessionId: sessionId, turnId: turnId);
      }
    }
    throw FormatException('Tool is unavailable for this turn: $name');
  }
}
