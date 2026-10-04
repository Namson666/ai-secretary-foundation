import 'package:ai_secretary/core/assistant/assistant_module.dart';
import 'package:flutter_test/flutter_test.dart';

class _LegacyModule extends AssistantModule {
  @override
  String get id => 'legacy';

  @override
  String get guidance => 'Legacy guidance';

  @override
  List<Map<String, dynamic>> get tools => [
    {
      'function': {'name': 'legacy_action'},
    },
  ];

  @override
  bool matches(String userText) => userText == 'legacy';

  @override
  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
  }) async => {'action_id': 42, 'session': sessionId, 'turn': turnId};

  @override
  bool isProposal(String toolName) => toolName == 'legacy_action';

  @override
  String describeProposal(Map<String, dynamic> proposal) => 'Confirm action 42';

  @override
  String? voiceDecision(String userText) => userText == '确认' ? 'confirm' : null;
}

void main() {
  test('a caller cannot add a duplicate module after registration', () {
    final input = <AssistantModule>[_LegacyModule()];
    final registry = AssistantModuleRegistry(input);
    input.add(_LegacyModule());
    expect(registry.select('legacy').length, 1);
  });

  test(
    'legacy selection, invocation and proposal hooks remain usable',
    () async {
      final module = _LegacyModule();
      final registry = AssistantModuleRegistry([module]);
      final selected = registry.select('legacy');
      expect(selected.single, same(module));
      final result = await AssistantModuleRegistry.invoke(
        selected,
        'legacy_action',
        {},
        sessionId: 'day-1',
        turnId: 'turn-1',
      );
      expect(result, {'action_id': 42, 'session': 'day-1', 'turn': 'turn-1'});
      final owner = AssistantModuleRegistry.ownerOf(selected, 'legacy_action')!;
      expect(owner.isProposal('legacy_action'), isTrue);
      expect(owner.voiceDecision('确认'), 'confirm');
      expect(owner.describeProposal(result), 'Confirm action 42');
      expect(AssistantModuleRegistry.guidanceFor(selected), 'Legacy guidance');
    },
  );
}
