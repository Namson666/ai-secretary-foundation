# 数字人底座接口说明书

> Codex 整理，2026-10-05。对应源项目 `1.0.15+16` 的底座源码，用于新项目的架构和模块接入。公开副本不含健康模块及第三方模型资源。本文描述的是**同一 Flutter/Android 工程内的 Dart、Riverpod 与 MethodChannel 接口**，不是已发布的跨进程 HTTP API、AAR 或稳定语义版本 SDK。总体说明见 [数字人底座说明](FOUNDATION_OVERVIEW.zh-CN.md)。

## 0. 阅读约定

- **现有**：当前源码存在并被当前入口调用。
- **部分/待验收**：代码已接线，但依赖云端开通、设备行为或用户实测。
- **建议**：新项目应建立的接口或规则，当前源码不提供。
- 下列函数签名是便于接入的摘要；泛型、可选参数和异常行为以链接的源文件为准。工具输入均不可信，模块必须自行校验。

## 1. 应用入口与装配

| 现有入口 | 职责 | 来源 |
| --- | --- | --- |
| `main_foundation.dart` | 检查 `FOUNDATION_APP=true`，初始化竖屏与 `ProviderScope`，启动 `FoundationApp` | [`main_foundation.dart`](../lib/main_foundation.dart) |
| `FoundationApp` | 注册 `/` 与 `/settings`，维护通话返回与前后台回调 | [`foundation_app.dart`](../lib/foundation_app.dart) |
| `assistantModuleRegistryProvider` | 默认仅装配通用 `WebSearchModule` | [`assistant_modules_provider.dart`](../lib/providers/assistant_modules_provider.dart) |
| 原工程 `main.dart` | 健康版覆盖上面的 provider，加入 `FitnessAssistantModule`；公开副本不包含 | 原工程实现 |
| `AppEdition.isFoundation` | 由 `--dart-define=FOUNDATION_APP=true` 决定；控制基础设置及健康信息提取 | [`app_edition.dart`](../lib/core/app_edition.dart) |

新项目应有独立入口、路由、Android flavor/包名和领域模块注册；**不能只修改底座 APK 的标题**。现有 `AppEdition` 只有布尔标志，不支持任意多版运行时配置；第三版需新增配置或把它改为明确的 edition 枚举（建议）。Android 两个现有包各有私有数据库，包名变更意味着新数据空间，不会自动迁移旧记忆。

## 2. 领域模块契约（现有，主要扩展点）

源码：[`AssistantModule`](../lib/core/assistant/assistant_module.dart)、[`AssistantModuleRegistry`](../lib/core/assistant/assistant_module.dart)。

```dart
abstract class AssistantModule {
  String get id;
  String get guidance;
  List<Map<String, dynamic>> get tools;
  bool matches(String userText);
  Future<Map<String, dynamic>> invoke(
    String name,
    Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
  });

  bool isProposal(String toolName);                    // 默认 false
  String describeProposal(Map<String, dynamic> data); // 默认抛 UnsupportedError
  String? voiceDecision(String userText);             // 默认 null
  Future<String> decide(int actionId, String decision,
      {required String sessionId});                   // 默认抛 UnsupportedError
  Future<void> afterAction();                         // 默认 no-op
  void afterTool(String name, Map<String, dynamic> result); // 默认 no-op
}
```

| 成员 | 调用语义与约束 |
| --- | --- |
| `id` | 注册表内唯一；健康模块现用 `fitness`，搜索模块现用 `web_search`。 |
| `matches(userText)` | **只看本轮用户输入**决定是否暴露模块指导与工具；现为关键词规则，不具备跨轮意图识别。普通聊天不要默认激活专科模块。 |
| `guidance` | 仅选中该模块时拼入系统提示；不能替代代码级参数校验、权限与确认。 |
| `tools` | OpenAI 风格 function-tool JSON schema；各模块的函数名在一个注册表中必须唯一。 |
| `invoke` | 被 `AssistantModuleRegistry.invoke` 分发；返回 JSON 可编码的结果。读取可直接返回数据；写入建议先创建待确认动作。 |
| 确认钩子 | `isProposal`/`describeProposal`/`voiceDecision`/`decide` 由语音流程调用；通用底座没有自动事务或通用待确认表，领域模块须自己实现。 |

`AssistantModuleRegistry` 构造时拒绝重复模块 ID/工具名；`select(text)`、`toolsFor(selected)`、`guidanceFor(selected)` 和 `invoke(...)` 只处理本轮入选模块。原工程健康模块以 `FitnessAssistantModule` 与 `TrainingTools` 示范真实数据读取及写入待确认单；公开副本不包含这两个实现，新领域应自行建立仓储与审批流程。

**新模块最小装配示意（建议代码，尚未创建）：**

```dart
final studyModuleRegistryProvider = Provider<AssistantModuleRegistry>((ref) {
  return AssistantModuleRegistry([
    WebSearchModule(ref.read(webSearchServiceProvider)),
    StudyAssistantModule(ref.read(studyToolsProvider)),
  ]);
});

// 新入口的 ProviderScope.overrides：
assistantModuleRegistryProvider.overrideWith(
  (ref) => ref.read(studyModuleRegistryProvider),
);
```

`StudyAssistantModule`、`studyToolsProvider` 和新入口均为**待开发**，不是可直接导入的现有类。`StudyAssistantModule.matches` 应只在学习问题上启用。领域仓储应持有课程/进度/错题的真实数据，工具返回带稳定 ID 与时间的结构化结果，不能让模型根据旧聊天猜测业务状态。需要写操作时由模块保存待确认请求，确认时重查数据与有效期，再提交事务。

## 3. 对话轮次与状态接口（现有）

源码：[`digital_human_provider.dart`](../lib/providers/digital_human_provider.dart)、[`home_screen.dart`](../lib/features/digital_human/screens/home_screen.dart)。

```dart
final digitalHumanProvider = NotifierProvider<DigitalHumanNotifier, DigitalHumanState>(...);

Future<void> startVoiceInput();  // 单次录音
Future<void> finishVoiceInput(); // 结束录音并识别/回答
Future<void> cancelVoiceInput();
Future<void> startCall();        // 持续通话；不支持 MiniMax 文件 ASR
Future<void> endCall();
Future<void> resumeCallIfNeeded();
Future<void> sendTextInput(String text); // 在数字人界面打字并经同一 TTS 流程回答
void stopCurrentOutput();        // 打断当前生成/播报
```

`DigitalHumanState` 暴露 `isRecording`、`isProcessing`、`isSpeaking`、`isCallActive`、`isInitialized`、`emotion`、`subtitleText`、`errorMessage`。这些布尔量不是互斥枚举：通话持续时一轮对话仍可处于处理或播报中。公共方法主要返回 `Future<void>`，调用方应监听 provider 的状态与错误，不应把 Future 完成误当作识别或回答成功。`reset()` 会请求结束通话并清理状态。

处理顺序：识别或文字输入 -> 提取用户事实 -> 选择模块 -> 读取相关记忆 -> 构造系统提示和最近消息 -> `LlmService.sendWithTools` -> 清理控制标签 -> 持久化对话/索引/摘要 -> TTS -> DUIX PCM 播放，数字人未挂载时回退普通播放器。`sendWithTools` 最多 5 轮、每轮最多 8 个工具调用；当前请求 `stream: false`，虽然返回类型为 `Stream<String>`，不等于实时逐 token API。[LLM 实现](../lib/services/llm_service.dart)

`HomeScreen` 当前可注入 `extraControls`、`onSpecialistTap`、`specialistLabel`、`bottomBarHeight`；新项目的领域入口和画面放在自己的应用壳/路由，避免领域 UI 反向依赖数字人渲染组件。首页离开时 DUIX PlatformView 会卸载；通话状态仍在 provider，切页后的音频可能走普通播放器。[首页参数](../lib/features/digital_human/screens/home_screen.dart)

## 4. 模型、语音和设置接口（现有）

| 接口 | 输入/输出 | 当前说明 |
| --- | --- | --- |
| `LlmService.sendWithTools(...)` | 消息、系统提示、工具 schema、`onTool` -> `Stream<String>` | 默认 `deepseek-flash`；DeepSeek 与 MiniMax 通过模型名分流。当前非真正流式工具轮次。[源码](../lib/services/llm_service.dart) |
| `LocalStreamingAsrService.prepare()` | `Future<void>` | 预载本地 sherpa-onnx 模型；模型资源随 APK。[源码](../lib/services/local_streaming_asr_service.dart) |
| `LocalStreamingAsrService.startConversation(...)` | `onPartial`、`onUtterance`、`onSpeechStart` | 本地持续麦克风识别；另有 `start`/`finish`/`cancel` 供单次录音。[源码](../lib/services/local_streaming_asr_service.dart) |
| `AliyunRealtimeAsrService.start(...)` | `onPartial`、`onFinal`、`onSpeechStart`、`onError` | 可选云实时识别；曾报告失败，需服务、密钥和真机验证。[源码](../lib/services/aliyun_realtime_asr_service.dart) |
| `MiniMaxFileAsrService.start/finish/cancel` | 录音后返回文字 | 不能作为持续通话的实时 ASR。[源码](../lib/services/minimax_file_asr_service.dart) |
| `TtsService.speak(text, emotion)` | `Future<void>` | MiniMax 2.8 HD/Turbo，全量音频请求、16 kHz 单声道 16-bit PCM；先走数字人，不能播放时回退普通音频。[源码](../lib/services/tts_service.dart) |
| `TtsService.stop()` | `Future<void>` | 取消请求/播放并清理临时文件；`dispose()` 释放资源。[源码](../lib/services/tts_service.dart) |
| `SettingsNotifier` | 音色、TTS 模型/语速、ASR 引擎、LLM 模型、性格 | `setTtsVoiceId`、`setTtsModel`、`setTtsSpeed`、`setAsrEngine`、`setLlmModel` 等；写 `user_preferences`。[源码](../lib/providers/settings_provider.dart) |

当前 `AsrEngine` 枚举为 `local`、`aliyunFlash`、`minimaxFile`；默认本地。TTS 语速范围 0.5–2.0，模型候选由 [`AppConstants`](../lib/core/utils/constants.dart) 限定。语气标签仅支持受控的 `happy/sad/surprised/calm` 等集合，普通回答不强制标注。[语气规则](../lib/core/assistant/speech_direction.dart)

**扩展限制**：`LlmService`、`TtsService` 与各 ASR 服务目前是具体类，而非统一 provider-neutral 抽象；新增供应商要改 provider/选择器与实现，不能只配置一个 URL。新项目若明确需要多模型热切换，应先统一音频格式、取消、partial/final、超时、错误和费用追踪契约（建议，现未实现）。

## 5. 记忆、检索与搜索接口（现有）

| 接口 | 作用与约束 |
| --- | --- |
| `MemoryService.buildContext(query, includeWorkoutHistory)` | 组合画像、RAG、相关事实；只有健康相关轮次才应注入训练上下文。[源码](../lib/services/memory_service.dart) |
| `buildApiMessagesForSession(sessionId, pendingUserText, limit: 16)` | 取同一会话最近消息并附本轮用户文本；语音与键盘使用每日会话 ID。[源码](../lib/services/memory_service.dart) |
| `persistVoiceTurn(...)` / `extractFromUserInput(...)` / `processAiResponse(...)` | 保存语音轮次、规则抽取、处理模型记忆标签。标签不是用户确认机制。[源码](../lib/services/memory_service.dart) |
| `RagService.search(query, limit: 8)` | 百炼 Embedding -> 本地 SQLite 候选余弦排序；索引读取上限最近更新的 500 份文档，失败时可返回空。[源码](../lib/services/rag_service.dart) |
| `EmbeddingProvider.embed(text)` | 可替换向量生成接口；当前实现调用百炼 `text-embedding-v4`。[源码](../lib/services/embedding_service.dart) |
| `RagVectorIndex.search(...)` | 可替换向量检索接口；当前 `SqliteRagVectorIndex` 在 Dart 中对候选排序。[源码](../lib/services/rag_service.dart) |
| `RagService.auditIndex()/repairIndex()` | 检查/修复缺失、损坏与孤立索引；底座设置界面未提供同等管理入口。[源码](../lib/services/rag_service.dart) |
| `WebSearchService.search(query)` | 抽象查询接口，返回含 `title`、`url`、`snippet` 的 `WebSearchHit`；当前实现为百炼 WebSearch MCP。[接口](../lib/core/search/web_search_service.dart) · [实现](../lib/core/search/bailian_web_search_service.dart) |

SQLite 表包括 `conversations`、`conversation_summaries`、`memories`、`memory_links`、`rag_documents`、`user_preferences`；当前共享 schema 也包含健康/训练表。[数据库](../lib/core/database/database_helper.dart) 同 key 记忆更新会直接替换值，并保留较高的重要度/置信度；尚无可靠的矛盾仲裁。`decayMemories()` 虽存在，未见常规调度调用；新项目若依赖记忆过期或删除，应补齐原始行、画像和 RAG 文档的事务一致性与测试。

底座**没有**已装入的通用专业知识库；其 RAG 主要面向个人资料与对话。WebSearch 只在明确联网或时效性问题上可被选中，返回最多 5 条有链接的结果；实际云服务可用性待验证。检索结果和网页文本属于外部数据，不得作为系统指令执行。[搜索模块](../lib/core/search/web_search_module.dart)

## 6. Android 原生通信契约（现有）

源码：[`MainActivity.kt`](../android/app/src/main/kotlin/com/namson/ai_secretary/MainActivity.kt)、[`DuixViewFactory.kt`](../android/app/src/main/kotlin/com/namson/ai_secretary/duix/DuixViewFactory.kt)、[`CallForegroundService`](../lib/services/call_foreground_service.dart)。

| Channel / View | 方法与参数 | 返回/事件 |
| --- | --- | --- |
| `com.namson.ai_secretary/config` | `getApiKey({key: String})`；键名包括 `minimax`、`deepseek`、`bailian_api_key`、`bailian_workspace_id` 等 | `String`，未知键返回空字符串。仅应用内部使用；**不是安全密钥仓库**。 |
| `com.namson.ai_secretary/call` | Dart -> Android: `start`、`stop` | Android -> Dart: `stopRequested`、`openRequested`。权限或服务启动失败可产生 `PlatformException`。 |
| Android `PlatformView` 类型 `com.namson.ai_secretary/duix_view` | 创建参数 `modelPath: '小秘'` | 创建后逐实例 Channel `com.namson.ai_secretary/duix_view_<viewId>`；准备就绪回调 `onDuixInitialized`。 |
| DUIX 实例 Channel | `playPcm({pcm: Uint8List})`、`stopAudio`、`setEmotion({emotion})`、`bodyAction({action})`；另有 `startPush/pushPcm/stopPush` | `playPcm` 需 16 kHz/单声道/16-bit PCM，成功播完返回 `true`，中止返回 `false`，错误为 `not_ready`、`invalid_pcm`、`audio_busy` 等。 |
| `com.namson.ai_secretary/duix` | `startRandomMotion` | 当前仅返回 `true`，不可当作实际动作控制能力。 |

[`AvatarAudioBridge`](../lib/services/avatar_audio_bridge.dart) 只在数字人视图已挂载、应用处于前台且 PCM 合法时尝试 `playPcm`，否则返回 `false` 供 TTS 走普通播放器。视图销毁后会 detach。`DuixAvatarView` 有情绪/身体动作调用，但某些低层调用会吞掉异常；新项目如需可靠遥测，应增加明确的结果/错误事件（建议）。DUIX 模型资源为专有格式；现有接口**不支持**把普通视频直接导入为兼容模型。

## 7. 接入新项目的执行顺序

1. 先定义应用 ID、flavor、入口、路由和模块 ID；确认新包是否需要与既有健康助手共享任何用户数据。现状默认不共享。
2. 为领域数据建表/迁移及仓储，不复用训练表表达其他业务。当前 `DatabaseHelper` 仍有健康表，应逐步拆到领域迁移（建议）。
3. 实现一个只读 `AssistantModule` 与真实数据工具，写选择/参数/无结果/错误测试；验证闲聊不会触发领域指导。
4. 再实现待确认写入，明确动作 ID、原值、拟变更、有效期、二次读取、幂等键与取消路径；语音确认和 UI 确认都需测试。
5. 如需专业知识，建独立的来源可追溯知识层；如需更换模型/数字人，先抽服务端口和统一错误语义。最后进行 APK 真机语音、背景、锁屏与口型验收。

### 必须保留的风险说明

- `BuildConfig` 中的密钥可从 APK 提取；公开分发前必须改后端代理/短期凭据，不能把密钥值写进新项目文档、源码或测试日志。
- 云 ASR、云搜索、Embedding、MiniMax TTS 可能产生费用；本文没有重新发起付费请求，也不以静态代码证明真实可用。
- 本地 SQLite 并非无限上下文；没有跨应用、跨设备或多人同步协议。多用户身份、领域命名空间、知识版本与隐私同意均属新项目设计事项。
- 前台服务通知不保证系统一定显示摄像头位置标记，也不保证所有厂商锁屏后仍持续录音。
