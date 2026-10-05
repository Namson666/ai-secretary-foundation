import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../study_runtime/study_conversation_runtime.dart';
import '../../../core/assistant/assistant_context.dart';
import 'study_providers.dart';
import 'study_tools.dart';

final studyFocusProvider = NotifierProvider<StudyFocus, String?>(
  StudyFocus.new,
);

class StudyFocus extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String? id) => state = id;
}

final FutureProvider<StudyTools> studyToolsProvider =
    FutureProvider<StudyTools>(
      (ref) async => StudyTools(
        await ref.watch(studyRepositoryProvider.future),
        await ref.watch(studyCatalogProvider.future),
        audioPlayer: (text, lease) => ref
            .read(studyRuntimeProvider)
            .playToolReference(text, isCurrent: lease),
      ),
    );
final Provider<StudyConversationRuntime>
studyRuntimeProvider = Provider<StudyConversationRuntime>((ref) {
  final runtime = StudyConversationRuntime(
    captureContext: () {
      final id = ref.read(studyFocusProvider);
      return StudyInputContext(
        focusId: id,
        snapshot: AssistantContextSnapshot(
          namespace: 'english',
          moduleIds: {'study'},
          focus: id == null
              ? null
              : AssistantEntityRef(namespace: 'english', type: 'word', id: id),
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
        ),
        systemPrompt:
            '你是拾语英语学习伙伴。优先自然对话和英语练习，按用户当前意图回答。用study工具查真实学习状态与计划；用户明确提出收录才调用review_point_add。这个词绑定输入开始时冻结焦点。工具status=committed才可说已保存；schedule_status=pending只说已保存待安排。未自动发音评测，ASR文本不能当发音分数。考试中禁止提供答案。不要声称云端同步。',
      );
    },
    tools: StudyTools.specifications,
    onTool: (name, args, captured) async {
      final tools = await ref.read(studyToolsProvider.future);
      final command = captured.commandId;
      if (command == null) {
        return {
          'status': 'rejected',
          'code': 'INVALID_ARGUMENT',
          'message': '缺少可信命令标识。',
        };
      }
      final result = await tools.invoke(
        name,
        args,
        StudyToolContext(
          commandId: command,
          userText: captured.finalText ?? '',
          focusId: captured.focusId,
          isCurrent: () => captured.isCurrent,
        ),
      );
      return studyRefreshToolResult(
        result,
        ref.read(studyControllerProvider.notifier).refresh,
      );
    },
  );
  ref.listen(studyControllerProvider, (previous, next) {
    final quiet = next.asData?.value.preferences.quiet;
    if (quiet != null && quiet != previous?.asData?.value.preferences.quiet) {
      unawaited(runtime.setSpeaker(!quiet));
    }
  });
  if (ref.read(studyControllerProvider).asData?.value.preferences.quiet ==
      true) {
    unawaited(runtime.setSpeaker(false));
  }
  ref.onDispose(() => unawaited(runtime.close()));
  return runtime;
});
