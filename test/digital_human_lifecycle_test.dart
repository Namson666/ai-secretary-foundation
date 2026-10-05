import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_secretary/core/database/database_helper.dart';
import 'package:ai_secretary/providers/digital_human_provider.dart';
import 'package:ai_secretary/providers/settings_provider.dart';
import 'package:ai_secretary/services/aliyun_realtime_asr_service.dart';
import 'package:ai_secretary/services/local_streaming_asr_service.dart';
import 'package:ai_secretary/services/minimax_file_asr_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'helpers/runtime_fakes.dart';

class _LocalAsr extends LocalStreamingAsrService {
  int finishes = 0;
  int cancellations = 0;
  int recordingStarts = 0;
  int conversationStarts = 0;
  bool capturing = false;
  PartialTranscript? partial;
  PartialTranscript? utterance;
  void Function()? speechStart;
  String transcript = '这是语音问题';
  Object? finishError;
  Completer<void>? cancelGate;
  final cancelEntered = Completer<void>();

  @override
  Future<void> start(PartialTranscript onPartial) async {
    recordingStarts++;
    partial = onPartial;
    capturing = true;
  }

  @override
  Future<void> startConversation({
    required PartialTranscript onPartial,
    required PartialTranscript onUtterance,
    required void Function() onSpeechStart,
    void Function(Uint8List)? onPcm,
  }) async {
    conversationStarts++;
    partial = onPartial;
    utterance = onUtterance;
    speechStart = onSpeechStart;
    capturing = true;
  }

  @override
  Future<bool> get isCapturing async => capturing;

  @override
  Future<String> finish() async {
    finishes++;
    if (finishError != null) throw finishError!;
    return transcript;
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    if (!cancelEntered.isCompleted) cancelEntered.complete();
    await cancelGate?.future;
    capturing = false;
  }

  @override
  void dispose() {}
}

class _AliyunAsr extends AliyunRealtimeAsrService {
  int starts = 0;
  int finishes = 0;
  int stops = 0;
  bool capturing = false;
  bool stopAfterFinish = false;
  Completer<void>? startGate;
  Completer<void>? finishGate;
  final startEntered = Completer<void>();
  final finishEntered = Completer<void>();

  @override
  Future<void> start({
    required AsrTextCallback onPartial,
    required AsrTextCallback onFinal,
    required void Function() onSpeechStart,
    void Function(Object error)? onError,
  }) async {
    starts++;
    if (!startEntered.isCompleted) startEntered.complete();
    await startGate?.future;
    capturing = true;
  }

  @override
  Future<String> finish() async {
    finishes++;
    if (!finishEntered.isCompleted) finishEntered.complete();
    try {
      await finishGate?.future;
      return '';
    } finally {
      if (stopAfterFinish) await stop();
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    capturing = false;
  }

  @override
  void dispose() {}
}

class _FileAsr extends MiniMaxFileAsrService {
  int cancellations = 0;

  @override
  Future<void> cancel() async => cancellations++;

  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory databaseDirectory;
  late ControlledSettingsNotifier settings;
  late ControlledTtsService tts;
  late ControlledMemoryService memory;
  late ControlledLlmService llm;
  late ControlledLatencyService latency;
  late _LocalAsr local;
  late _AliyunAsr aliyun;
  late _FileAsr file;
  late ProviderContainer container;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    databaseDirectory = await Directory.systemTemp.createTemp(
      'voice_lifecycle_',
    );
    await databaseFactory.setDatabasesPath(databaseDirectory.path);
    await DatabaseHelper.instance.database;
  });

  tearDownAll(() async {
    await (await DatabaseHelper.instance.database).close();
    await databaseDirectory.delete(recursive: true);
  });

  setUp(() async {
    await (await DatabaseHelper.instance.database).delete('conversations');
    settings = ControlledSettingsNotifier();
    tts = ControlledTtsService();
    memory = ControlledMemoryService();
    llm = ControlledLlmService();
    latency = ControlledLatencyService();
    local = _LocalAsr();
    aliyun = _AliyunAsr();
    file = _FileAsr();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => settings),
        digitalHumanMemoryServiceProvider.overrideWithValue(memory),
        digitalHumanLlmServiceProvider.overrideWithValue(llm),
        digitalHumanLatencyServiceProvider.overrideWithValue(latency),
        digitalHumanTtsServiceProvider.overrideWithValue(tts),
        localStreamingAsrProvider.overrideWithValue(local),
        aliyunRealtimeAsrProvider.overrideWithValue(aliyun),
        miniMaxFileAsrProvider.overrideWithValue(file),
      ],
    );
  });

  tearDown(() => container.dispose());

  test('interrupted speed setting cannot start late speech', () async {
    settings.speedGate = Completer<void>();
    final notifier = container.read(digitalHumanProvider.notifier);
    final request = notifier.sendTextInput('语速慢一点');
    await settings.speedEntered.future;

    notifier.stopCurrentOutput();
    settings.speedGate!.complete();
    await request;

    expect(tts.spoken, isEmpty);
    expect(container.read(digitalHumanProvider).isSpeaking, isFalse);
    expect(container.read(settingsProvider).ttsSpeed, lessThan(1.0));
  });

  test(
    'old speed speech completion cannot clear newer speaking state',
    () async {
      tts.speechGate = Completer<void>();
      final notifier = container.read(digitalHumanProvider.notifier);
      final request = notifier.sendTextInput('语速慢一点');
      await tts.entered.future;

      notifier.stopCurrentOutput();
      notifier.setSpeaking(true);
      notifier.setSubtitle('新一轮正在播报');
      tts.speechGate!.complete();
      await request;

      final state = container.read(digitalHumanProvider);
      expect(state.isSpeaking, isTrue);
      expect(state.subtitleText, '新一轮正在播报');
    },
  );

  test(
    'recording finishes with its starting engine after settings change',
    () async {
      local.transcript = '';
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startVoiceInput();
      await settings.setAsrEngine(AsrEngine.aliyunFlash);
      await notifier.finishVoiceInput();

      expect(local.finishes, 1);
      expect(aliyun.finishes, 0);
      expect(container.read(digitalHumanProvider).isRecording, isFalse);
    },
  );

  test(
    'an ASR start finishing after release cannot leave capture running',
    () async {
      aliyun.startGate = Completer<void>();
      container.read(settingsProvider);
      await settings.setAsrEngine(AsrEngine.aliyunFlash);
      final notifier = container.read(digitalHumanProvider.notifier);
      final starting = notifier.startVoiceInput();
      await aliyun.startEntered.future;

      await notifier.finishVoiceInput();
      aliyun.startGate!.complete();
      await starting;

      expect(aliyun.capturing, isFalse);
      expect(aliyun.finishes, 0);
      expect(container.read(digitalHumanProvider).isRecording, isFalse);
    },
  );

  test(
    'a finishing recording retains ASR ownership until cleanup ends',
    () async {
      container.read(settingsProvider);
      await settings.setAsrEngine(AsrEngine.aliyunFlash);
      aliyun.finishGate = Completer<void>();
      aliyun.stopAfterFinish = true;
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startVoiceInput();
      final finishing = notifier.finishVoiceInput();
      await aliyun.finishEntered.future;

      await notifier.startVoiceInput();
      final startsBeforeCleanup = aliyun.starts;
      final recordingBeforeCleanup = container
          .read(digitalHumanProvider)
          .isRecording;
      aliyun.finishGate!.complete();
      await finishing;

      expect(startsBeforeCleanup, 1);
      expect(recordingBeforeCleanup, isFalse);
      await notifier.startVoiceInput();
      expect(aliyun.starts, 2);
      expect(aliyun.capturing, isTrue);
      await notifier.cancelVoiceInput();
    },
  );

  test(
    'cancelling does not admit new capture while ASR finish is pending',
    () async {
      container.read(settingsProvider);
      await settings.setAsrEngine(AsrEngine.aliyunFlash);
      aliyun.finishGate = Completer<void>();
      aliyun.stopAfterFinish = true;
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startVoiceInput();
      final finishing = notifier.finishVoiceInput();
      await aliyun.finishEntered.future;

      await notifier.cancelVoiceInput();
      await notifier.startCall();
      await notifier.startVoiceInput();
      final startsBeforeCleanup = aliyun.starts;
      final stateBeforeCleanup = container.read(digitalHumanProvider);
      aliyun.finishGate!.complete();
      await finishing;
      await notifier.endCall();
      await notifier.cancelVoiceInput();

      expect(startsBeforeCleanup, 1);
      expect(stateBeforeCleanup.isCallActive, isFalse);
      expect(stateBeforeCleanup.isRecording, isFalse);
      await notifier.startCall();
      expect(aliyun.starts, 2);
      expect(aliyun.capturing, isTrue);
      await notifier.endCall();
    },
  );

  test(
    'releasing a queued recording does not finish an older ASR input',
    () async {
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startCall();
      local.cancelGate = Completer<void>();
      final ending = notifier.endCall();
      await local.cancelEntered.future;

      final starting = notifier.startVoiceInput();
      final finishing = notifier.finishVoiceInput();
      await pumpEventQueue();
      final finishesBeforeCleanup = local.finishes;
      local.cancelGate!.complete();
      await Future.wait([ending, starting, finishing]);

      expect(finishesBeforeCleanup, 0);
      expect(local.finishes, 0);
      expect(local.recordingStarts, 0);
      expect(local.capturing, isFalse);
      expect(container.read(digitalHumanProvider).isRecording, isFalse);
      expect(llm.requests, isEmpty);
    },
  );

  test('cancel during ASR telemetry cannot start a late model turn', () async {
    latency.asrGate = Completer<void>();
    final notifier = container.read(digitalHumanProvider.notifier);
    await notifier.startVoiceInput();
    final finishing = notifier.finishVoiceInput();
    await latency.asrEntered.future;

    await notifier.cancelVoiceInput();
    latency.asrGate!.complete();
    await finishing;

    expect(llm.requests, isEmpty);
    expect(tts.spoken, isEmpty);
    expect(container.read(digitalHumanProvider).isProcessing, isFalse);
  });

  test(
    'cancelled ASR failure cannot replace a newer subtitle or error',
    () async {
      local.finishError = StateError('old recognition failure');
      latency.asrGate = Completer<void>();
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startVoiceInput();
      final finishing = notifier.finishVoiceInput();
      await latency.asrEntered.future;

      await notifier.cancelVoiceInput();
      notifier.setSubtitle('新一轮字幕');
      latency.asrGate!.complete();
      await finishing;

      final state = container.read(digitalHumanProvider);
      expect(state.subtitleText, '新一轮字幕');
      expect(state.errorMessage, isEmpty);
    },
  );

  test('cancel targets only the engine that owns the recording', () async {
    final notifier = container.read(digitalHumanProvider.notifier);
    await notifier.startVoiceInput();
    await settings.setAsrEngine(AsrEngine.aliyunFlash);
    await notifier.cancelVoiceInput();

    expect(local.cancellations, 1);
    expect(aliyun.stops, 0);
    expect(file.cancellations, 0);
  });

  test('provider disposal suppresses late transcript callbacks', () async {
    final notifier = container.read(digitalHumanProvider.notifier);
    await notifier.startVoiceInput();
    final latePartial = local.partial!;
    container.dispose();

    expect(() => latePartial('迟到字幕'), returnsNormally);
  });

  test(
    'invalidating the notifier releases its active microphone capture',
    () async {
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startVoiceInput();
      container.invalidate(digitalHumanProvider);
      await container.pump();

      expect(local.cancellations, 1);
      expect(aliyun.stops, 0);
      expect(file.cancellations, 0);
    },
  );

  test('invalidating a live call releases its owning ASR capture', () async {
    final notifier = container.read(digitalHumanProvider.notifier);
    await notifier.startCall();
    expect(local.capturing, isTrue);
    container.invalidate(digitalHumanProvider);
    await container.pump();

    expect(local.capturing, isFalse);
    expect(local.cancellations, 1);
    expect(aliyun.stops, 0);
  });

  test(
    'explicit hangup while resume is stopping capture prevents restart',
    () async {
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startCall();
      local.capturing = false;
      local.cancelGate = Completer<void>();
      final resuming = notifier.resumeCallIfNeeded();
      await local.cancelEntered.future;

      final hangingUp = notifier.endCall();
      local.cancelGate!.complete();
      await hangingUp;
      await resuming;

      expect(container.read(digitalHumanProvider).isCallActive, isFalse);
      expect(local.conversationStarts, 1);
    },
  );

  test('restarting a call waits for the old capture teardown', () async {
    final notifier = container.read(digitalHumanProvider.notifier);
    await notifier.startCall();
    local.cancelGate = Completer<void>();
    final ending = notifier.endCall();
    await local.cancelEntered.future;

    final starting = notifier.startCall();
    await pumpEventQueue();
    final startsBeforeCleanup = local.conversationStarts;
    local.cancelGate!.complete();
    await Future.wait([ending, starting]);

    expect(startsBeforeCleanup, 1);
    expect(local.conversationStarts, 2);
    expect(local.capturing, isTrue);
    expect(container.read(digitalHumanProvider).isCallActive, isTrue);
  });

  test('voice input waits for a closing call on the shared ASR', () async {
    final notifier = container.read(digitalHumanProvider.notifier);
    await notifier.startCall();
    local.cancelGate = Completer<void>();
    final ending = notifier.endCall();
    await local.cancelEntered.future;

    final recording = notifier.startVoiceInput();
    await pumpEventQueue();
    final startsBeforeCleanup = local.recordingStarts;
    local.cancelGate!.complete();
    await Future.wait([ending, recording]);

    expect(startsBeforeCleanup, 0);
    expect(local.recordingStarts, 1);
    expect(local.capturing, isTrue);
    expect(container.read(digitalHumanProvider).isRecording, isTrue);
  });

  test(
    'call input waits for a cancelled recording on the shared ASR',
    () async {
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startVoiceInput();
      local.cancelGate = Completer<void>();
      final cancelling = notifier.cancelVoiceInput();
      await local.cancelEntered.future;

      final calling = notifier.startCall();
      await pumpEventQueue();
      final startsBeforeCleanup = local.conversationStarts;
      local.cancelGate!.complete();
      await Future.wait([cancelling, calling]);

      expect(startsBeforeCleanup, 0);
      expect(local.conversationStarts, 1);
      expect(local.capturing, isTrue);
      expect(container.read(digitalHumanProvider).isCallActive, isTrue);
    },
  );

  test(
    'speech start interrupts speed feedback while its setting is saving',
    () async {
      settings.speedGate = Completer<void>();
      final notifier = container.read(digitalHumanProvider.notifier);
      await notifier.startCall();
      local.speechStart!();
      local.utterance!('语速慢一点');
      await settings.speedEntered.future;

      local.speechStart!();
      settings.speedGate!.complete();
      await pumpEventQueue();

      expect(tts.spoken, isEmpty);
      expect(container.read(settingsProvider).ttsSpeed, 0.85);
      expect(container.read(digitalHumanProvider).subtitleText, '正在聆听...');
      await notifier.endCall();
    },
  );
}
