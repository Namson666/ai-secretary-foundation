class SpeechDirection {
  static const emotions = {
    'happy',
    'sad',
    'angry',
    'fearful',
    'disgusted',
    'surprised',
    'calm',
  };

  static final _toneTag = RegExp(
    r'\[TONE:\s*([a-z]+)\s*\]',
    caseSensitive: false,
  );

  static String? emotionFrom(String rawResponse) {
    final value = _toneTag.firstMatch(rawResponse)?.group(1)?.toLowerCase();
    return emotions.contains(value) ? value : null;
  }

  static String removeTags(String text) => text.replaceAll(_toneTag, '').trim();
}
