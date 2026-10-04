class WebSearchHit {
  final String title;
  final Uri url;
  final String snippet;

  const WebSearchHit({
    required this.title,
    required this.url,
    required this.snippet,
  });

  Map<String, String> toJson() => {
    'title': title,
    'url': url.toString(),
    'snippet': snippet,
  };
}

abstract class WebSearchService {
  Future<List<WebSearchHit>> search(String query);
}
