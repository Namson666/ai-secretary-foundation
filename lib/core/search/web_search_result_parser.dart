import 'dart:convert';

import 'web_search_service.dart';

class WebSearchResultParser {
  static List<WebSearchHit> parse(Object? data) {
    final hits = <WebSearchHit>[];
    final seen = <String>{};

    void visit(Object? value, int depth) {
      if (depth > 6 || hits.length >= 5) return;
      if (value is String) {
        try {
          visit(jsonDecode(value), depth + 1);
        } on FormatException {
          return;
        }
      } else if (value is List) {
        for (final item in value) {
          visit(item, depth + 1);
        }
      } else if (value is Map) {
        final title = value['title'] ?? value['name'];
        final link = value['url'] ?? value['link'];
        if (title is String && link is String) {
          final uri = Uri.tryParse(link);
          if (uri != null &&
              (uri.scheme == 'https' || uri.scheme == 'http') &&
              uri.host.isNotEmpty &&
              title.trim().isNotEmpty &&
              seen.add(uri.toString())) {
            final description =
                value['snippet'] ??
                value['summary'] ??
                value['description'] ??
                value['content'];
            hits.add(
              WebSearchHit(
                title: _limit(title.trim(), 160),
                url: uri,
                snippet: _limit(
                  description is String ? description.trim() : '',
                  600,
                ),
              ),
            );
          }
        }
        for (final child in value.values) {
          visit(child, depth + 1);
        }
      }
    }

    visit(data, 0);
    return hits;
  }

  static String _limit(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
}
