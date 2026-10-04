import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/search/bailian_web_search_service.dart';
import '../core/search/web_search_service.dart';

final webSearchServiceProvider = Provider<WebSearchService>(
  (ref) => BailianWebSearchService(),
);
