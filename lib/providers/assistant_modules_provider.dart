import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/assistant/assistant_module.dart';
import '../core/search/web_search_module.dart';
import 'web_search_provider.dart';

final assistantModuleRegistryProvider = Provider<AssistantModuleRegistry>(
  (ref) => AssistantModuleRegistry([
    WebSearchModule(ref.read(webSearchServiceProvider)),
  ]),
);
