import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/constants.dart';
import '../../../models/personality.dart';
import '../../../providers/digital_human_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../services/minimax_voice_catalog.dart';
import '../../../services/tts_service.dart';
import '../../../shared/theme/app_theme.dart';

class FoundationSettingsScreen extends ConsumerStatefulWidget {
  const FoundationSettingsScreen({super.key});

  @override
  ConsumerState<FoundationSettingsScreen> createState() =>
      _FoundationSettingsScreenState();
}

class _FoundationSettingsScreenState
    extends ConsumerState<FoundationSettingsScreen> {
  String? _previewing;
  double? _speedDraft;
  late final TtsService _preview = TtsService(
    preferAvatar: false,
    voiceId: () => _previewing ?? ref.read(settingsProvider).ttsVoiceId,
    model: () => ref.read(settingsProvider).ttsModel,
    speed: () => ref.read(settingsProvider).ttsSpeed,
  );

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  Future<void> _play(MiniMaxVoice voice) async {
    if (_previewing != null) return;
    if (ref.read(digitalHumanProvider).isCallActive) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先结束实时通话')));
      return;
    }
    setState(() => _previewing = voice.id);
    try {
      await _preview.speak('你好，今天想聊些什么？');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('试听失败，请检查网络和语音服务')));
      }
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  Future<void> _chooseVoice() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceColor,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .78,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '选择回复音色',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: MiniMaxVoiceCatalog.voices.length,
                  itemBuilder: (context, index) {
                    final voice = MiniMaxVoiceCatalog.voices[index];
                    return ListTile(
                      title: Text(voice.name),
                      subtitle: Text(voice.category),
                      selected:
                          ref.read(settingsProvider).ttsVoiceId == voice.id,
                      onTap: () async {
                        await ref
                            .read(settingsProvider.notifier)
                            .setTtsVoiceId(voice.id);
                        if (sheetContext.mounted) {
                          Navigator.of(sheetContext).pop();
                        }
                      },
                      trailing: IconButton(
                        tooltip: '试听${voice.name}',
                        onPressed: _previewing == null
                            ? () => _play(voice)
                            : null,
                        icon: const Icon(Icons.play_arrow),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final speed = _speedDraft ?? settings.ttsSpeed;
    final voice = MiniMaxVoiceCatalog.find(settings.ttsVoiceId);
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        title: const Text('基础设置'),
        backgroundColor: AppTheme.backgroundColor,
      ),
      body: ListView(
        children: [
          const _SectionLabel('语音'),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: const Text('语音识别'),
            subtitle: Text(switch (settings.asrEngine) {
              AsrEngine.local => '本地实时',
              AsrEngine.aliyunFlash => '阿里百炼 Flash 实时',
              AsrEngine.minimaxFile => 'MiniMax ASR 1.0 录音后识别',
            }),
            onTap: () => _pick<AsrEngine>(
              '语音识别',
              AsrEngine.values,
              (value) => switch (value) {
                AsrEngine.local => '本地实时',
                AsrEngine.aliyunFlash => '阿里百炼 Flash 实时',
                AsrEngine.minimaxFile => 'MiniMax ASR 1.0 录音后识别',
              },
              (value) =>
                  ref.read(settingsProvider.notifier).setAsrEngine(value),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq),
            title: const Text('回复音色'),
            subtitle: Text(voice?.name ?? settings.ttsVoiceId),
            onTap: _chooseVoice,
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('语音合成'),
            subtitle: Text(settings.ttsModel),
            onTap: () => _pick<String>(
              '语音合成',
              AppConstants.ttsChoices,
              (value) => value,
              (value) => ref.read(settingsProvider.notifier).setTtsModel(value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.speed),
                const SizedBox(width: 16),
                const Text('回复语速'),
                Expanded(
                  child: Slider(
                    value: speed,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${speed.toStringAsFixed(1)} 倍',
                    onChanged: (value) => setState(() => _speedDraft = value),
                    onChangeEnd: (value) {
                      ref.read(settingsProvider.notifier).setTtsSpeed(value);
                      setState(() => _speedDraft = null);
                    },
                  ),
                ),
                Text('${speed.toStringAsFixed(1)}×'),
              ],
            ),
          ),
          const Divider(height: 24),
          const _SectionLabel('对话'),
          ListTile(
            leading: const Icon(Icons.psychology_outlined),
            title: const Text('对话模型'),
            subtitle: Text(settings.llmModel),
            onTap: () => _pick<String>(
              '对话模型',
              AppConstants.llmChoices,
              (value) => value,
              (value) => ref.read(settingsProvider.notifier).setLlmModel(value),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.face_outlined),
            title: const Text('对话风格'),
            subtitle: Text(settings.personality.name),
            onTap: () => _pick<PersonalityType>(
              '对话风格',
              const [
                PersonalityType.professional,
                PersonalityType.energetic,
                PersonalityType.gentle,
                PersonalityType.calm,
              ],
              (value) => switch (value) {
                PersonalityType.professional => '专业',
                PersonalityType.energetic => '活力',
                PersonalityType.gentle => '温柔',
                PersonalityType.calm => '冷静',
                PersonalityType.custom => '自定义',
              },
              (value) {
                ref
                    .read(settingsProvider.notifier)
                    .setPersonality(
                      Personality(
                        type: value,
                        name: switch (value) {
                          PersonalityType.professional => '专业',
                          PersonalityType.energetic => '活力',
                          PersonalityType.gentle => '温柔',
                          PersonalityType.calm => '冷静',
                          PersonalityType.custom => '自定义',
                        },
                        description: '',
                      ),
                    );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pick<T>(
    String title,
    List<T> values,
    String Function(T) label,
    FutureOr<void> Function(T) onSelect,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(title, style: const TextStyle(fontSize: 18)),
            ),
            for (final value in values)
              ListTile(
                title: Text(label(value)),
                onTap: () async {
                  await onSelect(value);
                  if (sheetContext.mounted) Navigator.of(sheetContext).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
    child: Text(
      label,
      style: const TextStyle(
        color: AppTheme.primaryColor,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
