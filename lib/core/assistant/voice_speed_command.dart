enum VoiceSpeedCommand { faster, slower, normal }

class VoiceSpeedCommands {
  static VoiceSpeedCommand? parse(String input) {
    final text = input.trim().replaceAll(RegExp(r'[，。！？,.!?\s]'), '');
    if (text.isEmpty || text.length > 18) return null;
    if (RegExp(r'^(说话|语速|声音)?(快一点|快点|说快点|加快语速)$').hasMatch(text)) {
      return VoiceSpeedCommand.faster;
    }
    if (RegExp(r'^(说话|语速|声音)?(慢一点|慢点|说慢点|放慢语速)$').hasMatch(text)) {
      return VoiceSpeedCommand.slower;
    }
    if (RegExp(r'^(语速|说话)?(恢复正常|正常速度|调回正常|恢复默认)$').hasMatch(text)) {
      return VoiceSpeedCommand.normal;
    }
    return null;
  }

  static double apply(VoiceSpeedCommand command, double current) {
    return switch (command) {
      VoiceSpeedCommand.faster =>
        ((current + 0.15) * 100).round().clamp(50, 200) / 100,
      VoiceSpeedCommand.slower =>
        ((current - 0.15) * 100).round().clamp(50, 200) / 100,
      VoiceSpeedCommand.normal => 1.0,
    };
  }
}
