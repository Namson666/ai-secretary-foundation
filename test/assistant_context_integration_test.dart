import 'dart:async';
import 'dart:io';

import 'package:ai_secretary/core/app_profile.dart';
import 'package:ai_secretary/core/assistant/assistant_context.dart';
import 'package:ai_secretary/core/assistant/assistant_module.dart';
import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/models/message.dart';
import 'package:ai_secretary/providers/assistant_modules_provider.dart';
import 'package:ai_secretary/providers/chat_provider.dart';
import 'package:ai_secretary/providers/digital_human_provider.dart';
import 'package:ai_secretary/providers/settings_provider.dart';
import 'package:ai_secretary/services/llm_service.dart';
import 'package:ai_secretary/services/local_streaming_asr_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/runtime_fakes.dart';

class _FocusModule extends AssistantModule {
  final contexts = <AssistantContextSnapshot?>[];

  @override
  String get id => 'study_words';
  @override
  String get guidance => 'Use the captured word reference for this request.';
  @override
  List<Map<String, dynamic>> get tools => [
    {
      'type': 'function',
      'function': {
        'name': 'review_add',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    },
  ];
  @override
  bool matches(String text) => false;

  @override
  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
  }) async => {'error': 'A word reference is required'};

  @override
  Future<Map<String, dynamic>> invokeWithContext(
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
    AssistantContextSnapshot? context,
  }) async {
    contexts.add(context);
    return {'ok': true, 'wordId': context?.focus?.id};
  }
}

class _ToolLlm extends LlmService {
  final prompts = <String>[];

  @override
  Future<Map<String, dynamic>> requestToolTurn(
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
  ) async {
    prompts.add(messages.first['content'] as String);
    if (tools.isNotEmpty && !messages.any((m) => m['role'] == 'tool')) {
      return {
        'role': 'assistant',
        'tool_calls': [
          {
            'id': 'call-1',
            'type': 'function',
            'function': {'name': 'review_add', 'arguments': '{}'},
          },
        ],
      };
    }
    return {'role': 'assistant', 'content': '测试完成'};
  }
}

class _InputMemory extends ControlledMemoryService {
  final extractionEntered = Completer<void>();
  Completer<void>? extractionGate;

  @override
  Future<void> extractFromUserInput(String userInput) async {
    if (!extractionEntered.isCompleted) extractionEntered.complete();
    await extractionGate?.future;
  }

  @override
  Future<List<Map<String, String>>> buildApiMessagesForSession({
    required String sessionId,
    required String pendingUserText,
    int limit = 16,
  }) async => [
    {'role': 'user', 'content': pendingUserText},
  ];

  @override
  Future<List<Message>> persistVoiceTurn({
    required String sessionId,
    required String userText,
    required String assistantRawContent,
    bool extractUserMemory = true,
  }) async => [];
}

class _InputAsr extends LocalStreamingAsrService {
  void Function()? speechStart;
  PartialTranscript? utterance;

  @override
  Future<void> start(PartialTranscript onPartial) async {}
  @override
  Future<String> finish() async => '把这个加入复习';
  @override
  Future<void> cancel() async {}
  @override
  void dispose() {}
  @override
  Future<void> startConversation({
    required PartialTranscript onPartial,
    required PartialTranscript onUtterance,
    required void Function() onSpeechStart,
  }) async {
    speechStart = onSpeechStart;
    utterance = onUtterance;
  }
}

AssistantContextSnapshot _word(String id) => AssistantContextSnapshot(
  namespace: 'study',
  moduleIds: {'study_words'},
  focus: AssistantEntityRef(namespace: 'study', type: 'word', id: id),
  expiresAt: DateTime.now().add(const Duration(minutes: 5)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory databaseDirectory;
  late ProviderContainer container;
  late _FocusModule module;
  late _ToolLlm llm;
  late _InputMemory memory;
  late _InputAsr asr;
  late ControlledTtsService tts;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    databaseDirectory = await Directory.systemTemp.createTemp('input_context_');
    await databaseFactory.setDatabasesPath(databaseDirectory.path);
    await DatabaseHelper.instance.database;
  });
  tearDownAll(() async {
    await (await DatabaseHelper.instance.database).close();
    await databaseDirectory.delete(recursive: true);
  });
  setUp(() async {
    await (await DatabaseHelper.instance.database).delete('conversations');
    module = _FocusModule();
    llm = _ToolLlm();
    memory = _InputMemory();
    asr = _InputAsr();
    tts = ControlledTtsService();
    container = ProviderContainer(
      overrides: [
        assistantAppProfileProvider.overrideWithValue(
          AppProfile(
            id: 'study',
            dataNamespace: 'study',
            allowedModuleIds: {'study_words'},
          ),
        ),
        assistantModuleRegistryProvider.overrideWithValue(
          AssistantModuleRegistry([module]),
        ),
        settingsProvider.overrideWith(ControlledSettingsNotifier.new),
        memoryServiceProvider.overrideWithValue(memory),
        llmServiceProvider.overrideWithValue(llm),
        aiLatencyServiceProvider.overrideWithValue(ControlledLatencyService()),
        digitalHumanMemoryServiceProvider.overrideWithValue(memory),
        digitalHumanLlmServiceProvider.overrideWithValue(llm),
        digitalHumanLatencyServiceProvider.overrideWithValue(
          ControlledLatencyService(),
        ),
        digitalHumanTtsServiceProvider.overrideWithValue(tts),
        localStreamingAsrProvider.overrideWithValue(asr),
      ],
    );
  });
  tearDown(() => container.dispose());

  void showWord(String id) =>
      container.read(assistantContextProvider.notifier).setContext(_word(id));

  void expectWord(String id) {
    expect(module.contexts.map((context) => context?.focus?.id), [id]);
    expect(llm.prompts.first, contains('"id":"$id"'));
  }

  test(
    'chat captures context before persisting or indexing the input',
    () async {
      showWord('word-a');
      memory.userIndexGate = Completer<void>();
      final request = container
          .read(chatProvider.notifier)
          .sendMessage('把这个加入复习');
      await memory.userIndexEntered.future;
      showWord('word-b');
      memory.userIndexGate!.complete();
      await request;
      await memory.assistantIndexEntered.future;
      await pumpEventQueue();
      expectWord('word-a');
    },
  );

  test(
    'avatar text keeps context across asynchronous memory extraction',
    () async {
      showWord('word-a');
      memory.extractionGate = Completer<void>();
      final request = container
          .read(digitalHumanProvider.notifier)
          .sendTextInput('把这个加入复习');
      await memory.extractionEntered.future;
      showWord('word-b');
      memory.extractionGate!.complete();
      await request;
      expectWord('word-a');
    },
  );

  test(
    'single recording keeps its starting focus until transcription',
    () async {
      showWord('word-a');
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startVoiceInput();
      showWord('word-b');
      await notifier.finishVoiceInput();
      expectWord('word-a');
    },
  );

  test(
    'a call captures focus at speech start rather than call or final time',
    () async {
      showWord('word-before-call');
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startCall();
      showWord('word-at-speech');
      asr.speechStart!();
      showWord('word-after-speech');
      asr.utterance!('把这个加入复习');
      await tts.entered.future;
      await pumpEventQueue();
      expectWord('word-at-speech');
      await notifier.endCall();
    },
  );

  test(
    'a cleared focus does not silently activate a contextual write',
    () async {
      showWord('word-a');
      container.read(assistantContextProvider.notifier).clear();
      await container
          .read(digitalHumanProvider.notifier)
          .sendTextInput('把这个加入复习');
      expect(module.contexts, isEmpty);
      expect(llm.prompts.first, isNot(contains('word-a')));
    },
  );

  test('a final without speech start cannot reuse the previous word', () async {
    showWord('word-a');
    final notifier = container.read(digitalHumanProvider.notifier);
    await notifier.startCall();
    asr.speechStart!();
    asr.utterance!('把这个加入复习');
    await tts.entered.future;
    await pumpEventQueue();
    expectWord('word-a');

    showWord('word-b');
    asr.utterance!('这个也加入复习');
    await pumpEventQueue();
    expect(module.contexts.map((context) => context?.focus?.id), ['word-a']);
    expect(llm.prompts.last, isNot(contains('word-a')));
    expect(llm.prompts.last, isNot(contains('word-b')));
    await notifier.endCall();
  });
}
