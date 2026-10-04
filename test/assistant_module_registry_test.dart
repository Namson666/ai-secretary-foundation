import 'package:ai_secretary/core/app_profile.dart';
import 'package:ai_secretary/core/assistant/assistant_context.dart';
import 'package:ai_secretary/core/assistant/assistant_module.dart';
import 'package:flutter_test/flutter_test.dart';

class _Module extends AssistantModule {
  @override
  final String id;
  final String keyword;
  final List<Map<String, dynamic>> definitions;
  AssistantContextSnapshot? receivedContext;

  _Module(this.id, this.keyword, String toolName)
    : definitions = [
        {
          'type': 'function',
          'function': {
            'name': toolName,
            'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
          },
        },
      ];

  @override
  String get guidance => 'Use $id tools for the active task.';

  @override
  List<Map<String, dynamic>> get tools => definitions;

  @override
  bool matches(String userText) => userText.contains(keyword);

  @override
  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
  }) async => {'owner': id, 'session': sessionId, 'turn': turnId};

  @override
  Future<Map<String, dynamic>> invokeWithContext(
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
    AssistantContextSnapshot? context,
  }) {
    receivedContext = context;
    return invoke(name, args, sessionId: sessionId, turnId: turnId);
  }
}

AppProfile _profile({Set<String>? allowed}) =>
    AppProfile(id: 'study', dataNamespace: 'study', allowedModuleIds: allowed);

AssistantContextSnapshot _focus({String namespace = 'study'}) =>
    AssistantContextSnapshot(
      namespace: namespace,
      moduleIds: {'words'},
      focus: AssistantEntityRef(
        namespace: namespace,
        type: 'word',
        id: 'word-42',
        revision: '7',
      ),
      expiresAt: DateTime.utc(2099),
    );

void main() {
  test('registration cannot be extended by mutating the supplied list', () {
    final modules = <AssistantModule>[_Module('words', '单词', 'word_lookup')];
    final registry = AssistantModuleRegistry(modules);
    modules.add(_Module('rogue', '单词', 'word_lookup'));
    expect(registry.modules.map((module) => module.id), ['words']);
    expect(() => registry.modules.clear(), throwsUnsupportedError);
  });

  test('duplicate tool names are rejected even for unrelated modules', () {
    expect(
      () => AssistantModuleRegistry([
        _Module('words', '单词', 'lookup'),
        _Module('exam', '考试', 'lookup'),
      ]),
      throwsArgumentError,
    );
  });

  test(
    'active context selects a module without repeating its keyword',
    () async {
      final words = _Module('words', '单词', 'word_lookup');
      final registry = AssistantModuleRegistry([words]);
      final focus = _focus();
      final selection = registry.capture(
        '把这个加入复习',
        profile: _profile(),
        context: focus,
      );
      expect(selection.modules, [words]);
      expect(selection.guidance, contains('word-42'));
      expect(
        await selection.invoke(
          'word_lookup',
          {},
          sessionId: 'day-a',
          turnId: 'turn-a',
        ),
        {'owner': 'words', 'session': 'day-a', 'turn': 'turn-a'},
      );
      expect(identical(words.receivedContext, focus), isTrue);
    },
  );

  test('profile exclusions apply to both keywords and context', () async {
    final registry = AssistantModuleRegistry([
      _Module('words', '单词', 'word_lookup'),
    ]);
    final selection = registry.capture(
      '这个单词加入复习',
      profile: _profile(allowed: {}),
      context: _focus(),
    );
    expect(selection.modules, isEmpty);
    expect(selection.context, isNull);
    expect(selection.guidance, isNot(contains('word-42')));
    await expectLater(
      selection.invoke('word_lookup', {}, sessionId: 'day-a', turnId: 'turn-a'),
      throwsFormatException,
    );
  });

  test('expired and foreign-namespace context cannot select a module', () {
    final registry = AssistantModuleRegistry([
      _Module('words', '单词', 'word_lookup'),
    ]);
    final expired = AssistantContextSnapshot(
      namespace: 'study',
      moduleIds: {'words'},
      expiresAt: DateTime.utc(2020),
    );
    for (final context in [expired, _focus(namespace: 'fitness')]) {
      final selection = registry.capture(
        '继续',
        profile: _profile(),
        context: context,
      );
      expect(selection.modules, isEmpty);
      expect(selection.context, isNull);
    }
  });

  test('captured tools and routing survive later schema mutations', () async {
    final words = _Module('words', '单词', 'word_lookup');
    final registry = AssistantModuleRegistry([words]);
    final selection = registry.capture('单词', profile: _profile());
    (words.definitions.single['function'] as Map)['name'] = 'changed_later';
    expect((selection.tools.single['function'] as Map)['name'], 'word_lookup');
    expect(
      () => (selection.tools.single['function'] as Map)['name'] = 'injected',
      throwsUnsupportedError,
    );
    expect(
      (await selection.invoke(
        'word_lookup',
        {},
        sessionId: 's',
        turnId: 't',
      ))['owner'],
      'words',
    );
    await expectLater(
      selection.invoke('changed_later', {}, sessionId: 's', turnId: 't'),
      throwsFormatException,
    );
  });

  test('profile cannot advertise an unregistered module', () {
    final registry = AssistantModuleRegistry([]);
    expect(
      () => registry.capture('hello', profile: _profile(allowed: {'missing'})),
      throwsArgumentError,
    );
  });

  test('registration freezes schemas before a selection is captured', () {
    final words = _Module('words', '继续', 'word_lookup');
    final exams = _Module('exams', '继续', 'exam_lookup');
    final registry = AssistantModuleRegistry([words, exams]);
    (words.definitions.single['function'] as Map)['name'] = 'exam_lookup';
    final selection = registry.capture('继续', profile: _profile());
    expect(selection.tools.map((tool) => (tool['function'] as Map)['name']), [
      'word_lookup',
      'exam_lookup',
    ]);
    expect(selection.ownerOf('word_lookup'), same(words));
    expect(selection.ownerOf('exam_lookup'), same(exams));
  });

  test('a captured context is rechecked for expiry before dispatch', () async {
    var now = DateTime.utc(2026, 10, 5, 9);
    final words = _Module('words', '单词', 'word_lookup');
    final registry = AssistantModuleRegistry([words], clock: () => now);
    final context = AssistantContextSnapshot(
      namespace: 'study',
      moduleIds: {'words'},
      expiresAt: now.add(const Duration(minutes: 1)),
    );
    final selection = registry.capture(
      '继续',
      profile: _profile(),
      context: context,
    );
    now = now.add(const Duration(minutes: 2));
    await expectLater(
      selection.invoke('word_lookup', {}, sessionId: 's', turnId: 't'),
      throwsFormatException,
    );
    expect(words.receivedContext, isNull);
  });
}
