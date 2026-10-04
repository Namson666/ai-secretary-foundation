import 'package:ai_secretary/core/assistant/voice_speed_command.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes direct spoken speed controls', () {
    expect(VoiceSpeedCommands.parse('语速慢一点。'), VoiceSpeedCommand.slower);
    expect(VoiceSpeedCommands.parse('说话快一点'), VoiceSpeedCommand.faster);
    expect(VoiceSpeedCommands.parse('恢复正常'), VoiceSpeedCommand.normal);
  });

  test('does not steal ordinary conversation', () {
    expect(VoiceSpeedCommands.parse('你能慢一点解释这个问题吗'), isNull);
    expect(VoiceSpeedCommands.parse('今天跑得快一点'), isNull);
  });

  test('speed steps are bounded and resettable', () {
    expect(VoiceSpeedCommands.apply(VoiceSpeedCommand.slower, 1), .85);
    expect(VoiceSpeedCommands.apply(VoiceSpeedCommand.faster, 1.95), 2);
    expect(VoiceSpeedCommands.apply(VoiceSpeedCommand.slower, .5), .5);
    expect(VoiceSpeedCommands.apply(VoiceSpeedCommand.normal, 1.3), 1);
  });
}
