class AppConstants {
  static const String appName = '数字人底座';
  static const String dbName = 'ai_secretary.db';
  static const int dbVersion = 6;

  // API 端点
  static const String llmBaseUrl = 'https://api.minimaxi.com/v1';
  static const String deepSeekBaseUrl = 'https://api.deepseek.com';
  static const String ttsBaseUrl = 'https://api.minimaxi.com/v1';
  static const String asrBaseUrl = 'https://asr.tencentcloudapi.com';
  static const String embeddingBaseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1';

  // 模型名称
  static const String llmModel = 'deepseek-flash';
  static const List<String> llmChoices = [
    llmModel,
    'MiniMax-M2.7-highspeed',
    'MiniMax-M3',
    'MiniMax-M3.1-Flash-Preview',
    'deepseek-flash',
    'deepseek-v4-pro',
  ];
  static const String ttsModel = 'speech-2.8-hd';
  static const List<String> ttsChoices = ['speech-2.8-turbo', ttsModel];
  static const String embeddingModel = 'text-embedding-v4';
  static const String ttsVoice = 'female-tianmei';

  // ASR 配置
  static const String asrEngineModel = '16k_zh';
  static const String asrRegion = 'ap-guangzhou';
  static const String asrVoiceFormat = 'wav';
  static const String asrVersion = '2019-06-14';
}
