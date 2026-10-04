import 'package:ai_secretary/core/app_profile.dart';
import 'package:ai_secretary/core/assistant/assistant_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a snapshot does not follow subsequent UI collection changes', () {
    final modules = <String>{'words'};
    final snapshot = AssistantContextSnapshot(
      namespace: 'study',
      moduleIds: modules,
      taskId: 'task-1',
      focus: const AssistantEntityRef(
        namespace: 'study',
        type: 'word',
        id: 'word-1',
      ),
      expiresAt: DateTime.utc(2099),
    );
    modules.clear();
    expect(snapshot.moduleIds, {'words'});
    expect(snapshot.toJson()['focus'], {
      'namespace': 'study',
      'type': 'word',
      'id': 'word-1',
    });
    expect(() => snapshot.moduleIds.clear(), throwsUnsupportedError);
  });

  test('focus from another namespace is rejected at creation', () {
    expect(
      () => AssistantContextSnapshot(
        namespace: 'study',
        moduleIds: {'words'},
        focus: const AssistantEntityRef(
          namespace: 'fitness',
          type: 'set',
          id: 'set-1',
        ),
        expiresAt: DateTime.utc(2099),
      ),
      throwsArgumentError,
    );
  });

  test('profile copies its allowlist so callers cannot widen access', () {
    final allowed = <String>{'words'};
    final profile = AppProfile(
      id: 'study',
      dataNamespace: 'study',
      allowedModuleIds: allowed,
    );
    allowed.add('fitness');
    expect(profile.allowsModule('words'), isTrue);
    expect(profile.allowsModule('fitness'), isFalse);
  });
}
