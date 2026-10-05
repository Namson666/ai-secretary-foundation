import 'dart:math' as math;
import 'dart:typed_data';

/// A small conservative onset gate on captured 16kHz mono PCM. Its only job is
/// to freeze domain context before decoding; Sherpa still determines the final
/// utterance boundaries and transcript. No pronunciation scoring is implied.
class StudyVoiceStartDetector {
  int _voicedSamples = 0;
  bool _started = false;
  void reset() {
    _voicedSamples = 0;
    _started = false;
  }

  bool add(Uint8List bytes) {
    if (_started || bytes.length < 2) return false;
    final pcm = ByteData.sublistView(bytes);
    final count = bytes.length ~/ 2;
    double energy = 0;
    for (var i = 0; i < count; i++) {
      final sample = pcm.getInt16(i * 2, Endian.little) / 32768;
      energy += sample * sample;
    }
    if (math.sqrt(energy / count) >= 0.018) {
      _voicedSamples += count;
    } else {
      _voicedSamples = 0;
    }
    if (_voicedSamples < 960) return false;
    _started = true;
    return true;
  }
}
