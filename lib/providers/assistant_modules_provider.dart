import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_profile.dart';
import '../core/assistant/assistant_context.dart';
import '../core/assistant/assistant_module.dart';
import '../core/search/web_search_module.dart';
import 'web_search_provider.dart';

/// Hosts override this together with their domain module registry.
final assistantAppProfileProvider = Provider<AppProfile>(
  (ref) => AppProfile(id: 'foundation', dataNamespace: 'legacy'),
);

final assistantContextProvider =
    NotifierProvider<AssistantContextNotifier, AssistantContextSnapshot?>(
      AssistantContextNotifier.new,
    );

class AssistantContextNotifier extends Notifier<AssistantContextSnapshot?> {
  @override
  AssistantContextSnapshot? build() {
    // A new host profile must not inherit the previous host's visible item.
    ref.watch(assistantAppProfileProvider);
    return null;
  }

  void setContext(AssistantContextSnapshot context) {
    if (context.namespace !=
        ref.read(assistantAppProfileProvider).dataNamespace) {
      throw ArgumentError('Context belongs to a different application');
    }
    state = context;
  }

  void clear() => state = null;
}

final assistantModuleRegistryProvider = Provider<AssistantModuleRegistry>(
  (ref) => AssistantModuleRegistry([
    WebSearchModule(ref.read(webSearchServiceProvider)),
  ]),
);

/// Bind the host and visible item before the first asynchronous input operation.
/// Voice recognition supplies the text later, without reading a newer UI focus.
class AssistantInputSnapshot {
  final AppProfile profile;
  final AssistantModuleRegistry registry;
  final AssistantContextSnapshot? context;

  AssistantInputSnapshot.capture(Ref ref)
    : profile = ref.read(assistantAppProfileProvider),
      registry = ref.read(assistantModuleRegistryProvider),
      context = ref.read(assistantContextProvider) {
    registry.validateProfile(profile);
  }

  /// Used only when a recognizer omits a speech-start event. In that case no
  /// screen item can safely be inferred from the time the transcript arrives.
  AssistantInputSnapshot.withoutContext(Ref ref)
    : profile = ref.read(assistantAppProfileProvider),
      registry = ref.read(assistantModuleRegistryProvider),
      context = null {
    registry.validateProfile(profile);
  }

  AssistantModuleSelection select(String text) =>
      registry.capture(text, profile: profile, context: context);
}
