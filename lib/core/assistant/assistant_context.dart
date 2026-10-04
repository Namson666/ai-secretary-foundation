/// A stable reference to the item visible when the user started an input.
///
/// The owning module resolves the reference and checks [revision] before a
/// business write. The conversation base does not interpret domain IDs.
class AssistantEntityRef {
  final String namespace;
  final String type;
  final String id;
  final String? revision;

  const AssistantEntityRef({
    required this.namespace,
    required this.type,
    required this.id,
    this.revision,
  });

  Map<String, dynamic> toJson() => {
    'namespace': namespace,
    'type': type,
    'id': id,
    if (revision != null) 'revision': revision,
  };
}

/// Immutable, short-lived context captured at the start of a text/voice input.
///
/// Replacing the UI's current context never retargets an in-flight input. Hosts
/// clear context when leaving a task and cancel input when it must not complete.
class AssistantContextSnapshot {
  final String namespace;
  final Set<String> moduleIds;
  final AssistantEntityRef? focus;
  final String? taskId;
  final DateTime expiresAt;

  AssistantContextSnapshot({
    required this.namespace,
    required Set<String> moduleIds,
    this.focus,
    this.taskId,
    required this.expiresAt,
  }) : moduleIds = Set<String>.unmodifiable(moduleIds) {
    if (namespace.trim().isEmpty ||
        this.moduleIds.any((id) => id.trim().isEmpty) ||
        (taskId != null && taskId!.trim().isEmpty)) {
      throw ArgumentError('Context identifiers must not be empty');
    }
    final entity = focus;
    if (entity != null &&
        (entity.namespace != namespace ||
            entity.type.trim().isEmpty ||
            entity.id.trim().isEmpty ||
            (entity.revision != null && entity.revision!.trim().isEmpty))) {
      throw ArgumentError('Focus must be a valid reference in this namespace');
    }
  }

  bool isExpiredAt(DateTime now) => !expiresAt.isAfter(now);

  Map<String, dynamic> toJson() => {
    'namespace': namespace,
    'moduleIds': moduleIds.toList(growable: false),
    if (focus != null) 'focus': focus!.toJson(),
    if (taskId != null) 'taskId': taskId,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };
}
