/// Capabilities exposed by the application that hosts the conversation base.
///
/// [dataNamespace] identifies UI context ownership. It does not partition the
/// legacy SQLite database; a consuming application must supply that separately.
class AppProfile {
  final String id;
  final String dataNamespace;
  final Set<String>? allowedModuleIds;

  AppProfile({
    required this.id,
    required this.dataNamespace,
    Set<String>? allowedModuleIds,
  }) : allowedModuleIds = allowedModuleIds == null
           ? null
           : Set<String>.unmodifiable(allowedModuleIds) {
    if (id.trim().isEmpty || dataNamespace.trim().isEmpty) {
      throw ArgumentError('Application ID and namespace must not be empty');
    }
    if (this.allowedModuleIds?.any((id) => id.trim().isEmpty) ?? false) {
      throw ArgumentError('Module IDs must not be empty');
    }
  }

  /// A null allowlist preserves hosts that override only the module registry.
  bool allowsModule(String id) => allowedModuleIds?.contains(id) ?? true;
}
