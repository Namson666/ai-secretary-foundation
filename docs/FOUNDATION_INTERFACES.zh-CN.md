# 数字人底座接口说明书

> 更新于 2026-10-05，包含本次应用/上下文契约和一致性修复。本文描述同一 Flutter/Android 工程内的 Dart、Riverpod 与 MethodChannel 接口；当前没有独立发布的 HTTP API、AAR 或稳定版本 SDK。公开副本不含健康模块、学习模块及第三方模型资源。总体关系见[底座说明](FOUNDATION_OVERVIEW.zh-CN.md)，实现与验证范围见[优化状态](FOUNDATION_OPTIMIZATION_STATUS.zh-CN.md)。

## 0. 阅读约定

- “现有”指当前仓库的实现；云接口、原生资源和设备行为仍需实际接入验收。
- “接入方实现”指领域应用负责的代码。本说明中的 `StudyAssistantModule`、学习仓储和学习页面均未在底座中创建。
- 函数签名为接入摘要；完整参数、返回值和异常以链接源码为准。
- 工具输入、页面引用、RAG 与网页内容都是数据，不能替代代码级参数校验、对象归属检查或业务授权。

## 1. 应用装配与 AppProfile

| 入口/配置 | 当前职责 | 来源 |
| --- | --- | --- |
| `main_foundation.dart` | 检查 `FOUNDATION_APP=true`，初始化竖屏与 `ProviderScope`，启动 `FoundationApp` | [入口](../lib/main_foundation.dart) |
| `FoundationApp` | 注册 `/`、`/settings`，验证应用允许列表，维护通话返回与前后台回调 | [应用壳](../lib/foundation_app.dart) |
| `assistantAppProfileProvider` | 默认 `AppProfile(id: 'foundation', dataNamespace: 'legacy')` | [Providers](../lib/providers/assistant_modules_provider.dart) |
| `assistantModuleRegistryProvider` | 默认仅装配通用 `WebSearchModule` | [Providers](../lib/providers/assistant_modules_provider.dart) |
| `assistantContextProvider` | 保存当前页面的短期对象引用；应用配置重建时清空 | [Providers](../lib/providers/assistant_modules_provider.dart) |
| `AppEdition.isFoundation` | 编译期布尔标志，仍控制基础设置及健康信息提取 | [旧版兼容开关](../lib/core/app_edition.dart) |

[`AppProfile`](../lib/core/app_profile.dart) 的字段：

```dart
AppProfile({
  required String id,
  required String dataNamespace,
  Set<String>? allowedModuleIds,
});
bool allowsModule(String id);
```

`id` 和 `dataNamespace` 必须非空。允许列表在构造时复制并设为不可修改；`null` 表示允许已注册的所有模块，保留旧应用只覆盖注册表的用法，空集合表示不允许任何模块。允许不代表一定入选，仍需匹配文本或有效上下文。`validateProfile(profile)` 会拒绝允许列表中未注册的模块 ID；应用壳及输入捕获都会校验。

**`dataNamespace` 当前只用于页面上下文归属验证。** 它没有增加 SQLite 命名空间列、隔离旧记忆查询、迁移数据库文件，也不自动切换 Android flavor、入口、路由或健康提取开关。新应用仍需安排这些工程和数据变化；现有 `FOUNDATION_APP` 兼容开关继续生效。

接入方装配示意，以下 `StudyAssistantModule`、`studyToolsProvider` 由学习应用实现：

```dart
// 新入口 ProviderScope 的 overrides：
[
  assistantAppProfileProvider.overrideWithValue(
    AppProfile(
      id: 'study',
      dataNamespace: 'study',
      allowedModuleIds: {'web_search', 'study_words'},
    ),
  ),
  assistantModuleRegistryProvider.overrideWith(
    (ref) => AssistantModuleRegistry([
      WebSearchModule(ref.read(webSearchServiceProvider)),
      StudyAssistantModule(ref.read(studyToolsProvider)),
    ]),
  ),
]
```

## 2. 页面对象与输入快照

源码：[`AssistantEntityRef`、`AssistantContextSnapshot`](../lib/core/assistant/assistant_context.dart)、[`AssistantInputSnapshot` 与 Providers](../lib/providers/assistant_modules_provider.dart)。

| 契约 | 字段/方法 | 语义 |
| --- | --- | --- |
| `AssistantEntityRef` | `namespace`、`type`、`id`、可选 `revision` | 稳定对象引用；`revision` 是领域自己解释的字符串，底座不会自动核对数据库版本。 |
| `AssistantContextSnapshot` | `namespace`、`moduleIds`、可选 `focus`、可选 `taskId`、`expiresAt` | 不可变的短期页面上下文；模块 ID 集合会复制。引用的 namespace 必须与上下文一致。 |
| `AssistantContextNotifier.setContext(context)` | 设置页面当前上下文 | 拒绝其他应用 namespace；空 ID、空任务 ID、无效 focus 在快照构造时拒绝。 |
| `AssistantContextNotifier.clear()` | 清空当前页面上下文 | 影响后续输入，不会追溯修改已经捕获的输入。 |
| `AssistantInputSnapshot.capture(ref)` | 保存应用配置、注册表及当前上下文 | 应在输入开始、第一次异步等待之前调用。 |
| `AssistantInputSnapshot.withoutContext(ref)` | 保存配置与注册表，context 为 `null` | 连续识别缺少 speech-start 事件时使用，避免按最终文本到达时的屏幕推断对象。 |
| `input.select(text)` | 调用所捕获注册表的 `capture(...)` | 文本可稍后由 ASR 提供，页面引用仍是开始输入时的那份。 |

学习页面可以这样发布上下文；对象类型、ID 和有效期由领域应用确定：

```dart
ref.read(assistantContextProvider.notifier).setContext(
  AssistantContextSnapshot(
    namespace: 'study',
    moduleIds: {'study_words'},
    focus: const AssistantEntityRef(
      namespace: 'study',
      type: 'word',
      id: 'word-42',
      revision: '7',
    ),
    taskId: 'review-session-12',
    expiresAt: DateTime.now().add(const Duration(minutes: 5)),
  ),
);
```

这里的五分钟只是示例，不是底座硬编码期限。离开任务时接入方应 `clear()`；若该次操作离开后不应继续，还必须取消正在进行的输入。仅清空当前页面不会撤销旧输入、删除已提交记录或让它自动改指向新对象。

现有对话入口使用下列捕获时机：

| 输入方式 | 捕获时机 | 后续行为 |
| --- | --- | --- |
| 聊天页 `sendMessage` | 保存/索引用户消息之前 | 提示、schema、工具路由使用同一快照。 |
| 数字人页 `sendTextInput` | 开始处理文字时 | 后续等待记忆、模型或 TTS 不读取更新后的页面焦点。 |
| 单次录音 `startVoiceInput` | 开始录音时 | 结束录音后用识别文本选模块，保持原页面引用及启动时 ASR 引擎。 |
| 持续通话 | 每段 `onSpeechStart` | 本段最终文本使用该快照；缺失此事件时使用 `withoutContext`，工具可据此要求明确对象。 |

## 3. 模块契约与本轮选择

源码：[`AssistantModule`、`AssistantModuleRegistry`、`AssistantModuleSelection`](../lib/core/assistant/assistant_module.dart)。

```dart
abstract class AssistantModule {
  String get id;
  String get guidance;
  List<Map<String, dynamic>> get tools;

  bool matches(String userText);
  bool matchesContext(AssistantContextSnapshot context);

  Future<Map<String, dynamic>> invoke(
    String name, Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
  });
  Future<Map<String, dynamic>> invokeWithContext(
    String name, Map<String, dynamic> args, {
    required String sessionId,
    required String turnId,
    AssistantContextSnapshot? context,
  });

  bool isProposal(String toolName);
  String describeProposal(Map<String, dynamic> data);
  String? voiceDecision(String userText);
  Future<String> decide(int actionId, String decision,
      {required String sessionId});
  Future<void> afterAction();
  void afterTool(String name, Map<String, dynamic> result);
}
```

以上为成员摘要；新增方法和确认钩子已有默认实现。`matchesContext` 默认检查 `context.moduleIds` 是否包含本模块 ID；`invokeWithContext` 默认转调旧 `invoke`。使用 `extends AssistantModule` 的旧模块可继承这些默认实现，本仓库 `WebSearchModule` 属于此类；直接 `implements AssistantModule` 的外部类仍需实现新增成员。上下文需要被解释时，领域模块再覆盖 `invokeWithContext`。

模块 ID 与 function-tool 名称必须在注册表内唯一且非空。注册时复制模块列表，并深度复制/冻结 JSON schema；后续修改原列表或原 schema 不会改变新流程捕获到的工具名和路由。模块对象自身仍由接入方实现，应保持 ID 和业务契约稳定。

新流程使用 `capture → selection`：

```dart
final selection = registry.capture(
  userText,
  profile: profile,
  context: capturedContext,
);

// 同一轮的模型提示与工具列表：
final guidance = selection.guidance;
final tools = selection.tools;

// 在现有 LLM 工具循环的 onTool 中分发：
final result = await selection.invoke(
  toolName,
  arguments,
  sessionId: sessionId,
  turnId: turnId,
);
```

在 Riverpod 对话入口，`AssistantInputSnapshot.capture(ref)` 负责先捕获三项输入，稍后通过 `input.select(userText)` 得到上面的 selection。底座已在现有入口接线；接入领域模块不需要另建第二个 LLM 工具循环。

| 选择/调用规则 | 行为 |
| --- | --- |
| 模块允许列表 | 先过滤未允许模块，再按文本或上下文选择。 |
| 上下文有效性 | namespace 必须匹配应用、未过期、模块集合非空，且集合中的所有模块均已注册并被允许；任一条件不满足便整体忽略此上下文。文本匹配仍可正常工作。 |
| 本轮快照 | `modules`、`tools`、路由和 guidance 在选择时固定；guidance 包含有效页面引用的 JSON 数据。 |
| `selection.ownerOf(name)` | 查询本轮已捕获的工具归属；未选中工具没有 owner。 |
| `selection.invoke(...)` | 只调用本轮捕获的工具；未知名称抛 `FormatException`。仅上下文指定的模块收到该 context。 |
| 调用前过期 | 对需要该上下文的模块，在实际分发前再次检查有效期；过期抛 `FormatException`，不会悄悄换成最新页面。 |

旧 `select(text)`、静态 `toolsFor/ownerOf/guidanceFor/invoke` 保留，以兼容旧调用方和模块身份。它们仍按旧模块对象读取信息，**不提供新 selection 的上下文、允许列表和冻结 schema 路由保证**。新增对话接线使用实例 `capture` 与 selection，避免混用两条路径。

## 4. 领域写入与确认策略

`invoke`/`invokeWithContext` 返回可 JSON 编码的 `Map`；底座没有通用“已提交”回执协议，也没有可持久化的业务动作账本。模型给出一句“已完成”或结果中没有 `error`，都不能替代领域仓储的真实提交结果。接入方应为写工具定义清楚的返回值，包含实际对象/记录 ID、操作结果及必要的版本信息。

现有 `isProposal`、`describeProposal`、`voiceDecision`、`decide`、`afterAction` 和 `afterTool` 钩子保持兼容；原健康模块的确认语义不改变。公开仓库没有该健康模块的实现，也没有通用待确认表。

学习工具可以按操作分别处理：

- 用户明确说“把这个加入复习”，且快照指向唯一对象、操作可逆时，可直接校验并执行，返回真实结果与撤销入口；无需统一再问一次。
- 对象不明确、引用过期或当前记录版本不符时，先明确目标或刷新数据，不能改用模型猜测的对象。
- 是否需要额外确认由领域操作的影响和既有规则决定。需要确认的工具自行管理动作 ID、有效期、幂等性、提交前复查和取消路径。

页面引用、聊天摘要和向量命中都不能代替学习计划、考试结果或复习记录的权威来源；这些数据应由领域仓储读写。

## 5. 对话状态与取消

主要入口：[`ChatNotifier`](../lib/providers/chat_provider.dart)、[`DigitalHumanNotifier`](../lib/providers/digital_human_provider.dart)。数字人公共方法保持原有形态：

```dart
Future<void> startVoiceInput();
Future<void> finishVoiceInput();
Future<void> cancelVoiceInput();
Future<void> startCall();
Future<void> endCall();
Future<void> resumeCallIfNeeded();
Future<void> sendTextInput(String text);
void stopCurrentOutput();
```

`DigitalHumanState` 提供 `isRecording`、`isProcessing`、`isSpeaking`、`isCallActive`、`isInitialized`、`emotion`、`subtitleText`、`errorMessage`。这些布尔量不是互斥状态枚举；持续通话期间一轮输入仍可处理或播报。公共方法通常返回 `Future<void>`，界面应监听状态与错误，不能只把 Future 完成当作识别/回答成功。

异步工作现在检查所属轮次和 provider 生命周期。聊天切换、清空、加载历史以及旧索引完成，不能覆盖较新轮次的消息和订阅；语速命令的设置等待也处于取消控制下。单次录音在结束/取消时使用启动时的 ASR 引擎，设置中途变更不会把旧录音交给另一个服务。旧播报完成不能清掉新播报的状态。界面取消不自动回滚已经提交的数据库记录。

通话与单次录音共用 ASR 清理队列，重新开始采集前等待旧清理结束；重复挂断会作废排队中的通话启动。有效的 `speechStart` 始终取消旧输出，因此语速设置仍在保存时开始下一句话，也不会触发过期语音反馈；已经保存的设置仍保留。历史会话列表查询也随 provider 生命周期失效，旧查询不能回填重建后的界面。

单次录音仍在排队或准备时松开按键，按取消处理，不调用尚未启动完成的识别器 `finish`。识别器的 `finish` 及其内部清理尚未完成时，两种输入入口均暂不接受新采集；界面取消不会提前释放这一归属。该限制在识别器完成后解除，不延伸到后续模型回复和语音播放，因此仍可正常打断输出。

处理主线仍为 ASR/文字 → 记忆和模块选择 → `LlmService.sendWithTools` → 记录与索引 → TTS → DUIX/普通播放器。`sendWithTools` 最多 5 轮、每轮最多 8 次工具调用；HTTP 请求当前 `stream: false`，返回类型为 `Stream<String>` 不表示真正逐 token 输出。[LLM 实现](../lib/services/llm_service.dart)

[`HomeScreen`](../lib/features/digital_human/screens/home_screen.dart) 可注入 `extraControls`、`onSpecialistTap`、`specialistLabel`、`bottomBarHeight`。领域路由和页面放在自己的应用壳，离开数字人首页会卸载 DUIX PlatformView；provider 中的通话状态可以继续存在。

## 6. 语音、模型与可选 SOE

| 接口 | 当前行为 | 来源 |
| --- | --- | --- |
| `LlmService.sendWithTools(...)` | 消息、提示、工具 schema、`onTool` → `Stream<String>`；默认 `deepseek-flash`，当前非逐 token 工具轮次 | [LLM](../lib/services/llm_service.dart) |
| `LocalStreamingAsrService` | `prepare` 预载模型；`start/finish/cancel` 单次录音；`startConversation` 提供 partial、utterance、speech-start | [本地 ASR](../lib/services/local_streaming_asr_service.dart) |
| `AliyunRealtimeAsrService` | 可选实时识别，提供 partial、final、speech-start、error 回调；需服务和真机验收 | [云实时 ASR](../lib/services/aliyun_realtime_asr_service.dart) |
| `MiniMaxFileAsrService` | 录音后识别；不能作为持续通话的实时 ASR | [文件 ASR](../lib/services/minimax_file_asr_service.dart) |
| `TtsService.speak(text, emotion)` | MiniMax 2.8 HD/Turbo，全量音频请求；16 kHz、单声道、16-bit PCM | [TTS](../lib/services/tts_service.dart) |
| `TtsService.stop/dispose` | 取消请求/播放、清理临时文件与资源 | [TTS](../lib/services/tts_service.dart) |
| `SettingsNotifier` | 音色、TTS 模型/语速、ASR 引擎、LLM 模型和性格，写入 `user_preferences` | [设置](../lib/providers/settings_provider.dart) |

当前 `AsrEngine` 为 `local`、`aliyunFlash`、`minimaxFile`，默认本地。TTS 语速为 0.5–2.0，模型候选由 [`AppConstants`](../lib/core/utils/constants.dart) 限定；语气标签由 [`SpeechDirection`](../lib/core/assistant/speech_direction.dart) 限定。

[`AvatarAudioBridge.play`](../lib/services/avatar_audio_bridge.dart) 在视图不存在或应用不在前台时返回 `false`；TTS 收到 `false` 且未取消时可使用同一 PCM 的 WAV 普通播放。已挂载视图收到非法 PCM 会抛错，原生播放异常也继续向上传播。异常清理只停止本次请求捕获的 Channel，清理错误不会覆盖原播放错误；不把这些异常改成静默普通播放。

**SOE 接入约束，尚未实现：** 腾讯 SOE 应在音频旁路异步评测，结果关联原输入轮次；关闭、超时或不可用时继续原有 ASR → LLM/工具 → TTS → DUIX 路径。提示纠音和“加入以后复习点”由后续学习模块处理，基础对话不等待 SOE 结果。当前尚无通用输入 PCM 观察端口、SOE 适配器或评测队列。

LLM/TTS/ASR/DUIX 仍主要使用具体实现类，未完成供应商中立端口或热插拔渲染器。增加服务时需明确格式、取消、超时和错误契约；这些属于后续工作。

## 7. 记忆、检索与搜索

| 接口 | 当前作用与约束 | 来源 |
| --- | --- | --- |
| `MemoryService.buildContext(...)` | 组合画像、RAG、相关事实；`includeWorkoutHistory` 控制训练历史路径，不是完整领域隔离 | [记忆服务](../lib/services/memory_service.dart) |
| `buildApiMessagesForSession(...)` | 读取同会话最近消息，默认 `limit: 16`，附本轮文本 | [记忆服务](../lib/services/memory_service.dart) |
| `persistVoiceTurn/extractFromUserInput/processAiResponse` | 保存轮次、规则提取、处理模型记忆标签；标签不代表用户确认 | [记忆服务](../lib/services/memory_service.dart) |
| `DatabaseHelper.insertMemory(entry)` | `Future<int>`；事务内同 key 查询与合并，保持旧返回 ID API | [数据库](../lib/core/database/database_helper.dart) |
| `RagService.search(query, limit: 8)` | Embedding → 向量检索 → 再核对已管理来源；检索失败可返回空 | [RAG](../lib/services/rag_service.dart) |
| `EmbeddingProvider.embed(text)` | 可替换向量生成接口；现有实现为百炼 `text-embedding-v4` | [Embedding](../lib/services/embedding_service.dart) |
| `RagVectorIndex.search(...)` | 可替换向量检索；默认 SQLite 先按来源有效性过滤，再按余弦分数排序 | [RAG](../lib/services/rag_service.dart) |
| `auditIndex/repairIndex` | 检查缺失、损坏、孤立及 `stale_document`；修复计数依据实际有效投影 | [RAG](../lib/services/rag_service.dart) |
| `WebSearchService.search(query)` | 返回 title、URL、snippet；通用模块按需调用，当前适配百炼 WebSearch MCP | [接口](../lib/core/search/web_search_service.dart) · [实现](../lib/core/search/bailian_web_search_service.dart) |

### 7.1 事实合并与画像

已有 `manual` 或 `user_input` 事实不会被同 key 的 `ai_extract` 覆盖，包括同值 AI 提取；后续明确用户更正仍可更新。值改变时使用新记录的置信度，不能继承旧矛盾值的高置信度；同值确认可保留较高置信度，重要度仍取较高值。

`MemoryService` 写入后，在短事务内重读数据库实际接受的记录，再更新画像投影；embedding 网络请求在事务外。被拒绝的 AI 候选不应进入画像/RAG，同一抽取事实也不再重复发起画像 embedding。这是对现有来源标记的有限冲突规则，没有新增完整来源历史或用户冲突审核界面。

SQLite 文件仍为 `ai_secretary.db`、schema 6，保留原表与迁移路径。新事务避免本路径并发插入同 key 的竞态，但不自动清理过去已存在的重复行，也未为旧表增加唯一键或命名空间。

### 7.2 RAG 当前性检查

已管理来源为 `memory`、`user_profile`、`conversation_message`、`conversation_summary`、`workout`。系统按当前源记录重新构建内容/元数据进行比对；memory 还检查有效期。索引前先验证一次，embedding 完成后在短写事务中再验证，防止源已删除或更改后旧结果重新落入索引。

默认 `SqliteRagVectorIndex` 按更新时间分页读取，跳过来源无效的投影后收集候选；`candidateLimit` 默认仍是 500，然后取向量排序结果，默认最多 8 条。失效投影不会占用这 500 个来源有效候选的位置，但超过预算的更早有效向量不会全部参与排序。自定义 `RagVectorIndex` 的结果也会接受已管理来源的返回前复查；复查剔除项目后，结果数可能少于请求值。

未知扩展 `source_type` 保持原有行为，底座不替它证明原始来源；这些校验也不是 namespace 或权限过滤。更正/删除一条事实不会自动更改旧聊天、摘要、画像里其他独立源记录对同一事实的提及。索引修复不是自动调度的同步服务；当前没有持久 outbox、失败重试队列、全量历史副本删除传播或跨设备协议。

底座 RAG 主要面向个人资料与对话，没有预装可追溯的专业知识库。课程内容、词典、考试题、词汇掌握状态应分别有真实来源和领域模型；学习进度不能仅靠聊天摘要推断。检索结果和网页文本仅作为参考数据。

## 8. Android 原生通信与回调所有权

源码：[`MainActivity.kt`](../android/app/src/main/kotlin/com/namson/ai_secretary/MainActivity.kt)、[`DuixViewFactory.kt`](../android/app/src/main/kotlin/com/namson/ai_secretary/duix/DuixViewFactory.kt)、[`CallForegroundService`](../lib/services/call_foreground_service.dart)。包名、Channel 名称和 PCM 格式未在本次改动。

| Channel / View | 方法与参数 | 返回/事件 |
| --- | --- | --- |
| `com.namson.ai_secretary/config` | `getApiKey({key: String})` | String；未知键返回空字符串。读取 BuildConfig，不是保密密钥仓库。 |
| `com.namson.ai_secretary/call` | Dart → Android：`start`、`stop` | Android → Dart：`stopRequested`、`openRequested`；服务/权限失败可产生 `PlatformException`。 |
| `com.namson.ai_secretary/duix_view` | PlatformView；创建参数 `modelPath: '小秘'` | 逐实例 Channel 为 `com.namson.ai_secretary/duix_view_<viewId>`；回调 `onDuixInitialized`。 |
| DUIX 实例 Channel | `playPcm({pcm: Uint8List})`、`stopAudio`、`setEmotion`、`bodyAction`；另有 `startPush/pushPcm/stopPush` | PCM 为 16 kHz/单声道/16-bit；播完 `true`、中止 `false`，错误如 `not_ready`、`invalid_pcm`、`audio_busy`。 |
| `com.namson.ai_secretary/duix` | `startRandomMotion` | 当前仅返回 `true`，不能据此认定实际动作已执行。 |

回调注册现在返回解除函数：

```dart
void Function() onStopRequested(Future<void> Function() callback);
void Function() onReturnRequested(void Function() callback);
```

实际为 `CallForegroundService` 静态方法。持有者应保存返回值，并在自己的 dispose 中调用；返回的解除函数只撤销本次注册，即使新持有者注册了同一个回调，旧解除函数也不会删掉新注册。原先忽略返回值的代码仍可编译。`start/stop` 仍只在 Android 发起原生调用。

DUIX 模型资源是指定格式；现有接口不支持任意普通视频导入。某些情绪/身体动作低层调用仍会吞掉异常，完整原生遥测契约未在本次抽取。

## 9. 新领域的接入顺序

1. 定义应用入口、路由、flavor/包名与 `AppProfile`，装配注册表并检查允许列表；明确旧数据是否需要迁移。
2. 为单词、计划、进度、考试等建领域仓储与迁移。当前底座没有这些业务表，不应借训练表表达学习记录。
3. 页面发布有期限的对象引用，实现只读工具和 `invokeWithContext`，验证普通聊天、对象切换、过期与跨应用引用。
4. 实现一种真实写入，例如明确加入复习；按领域规则处理幂等、版本、撤销和必要的确认，保留已有健康确认钩子。
5. 接入可选 SOE 旁路，验证关停、超时、延迟结果和语音加入复习；再推进供应商端口、数据库领域分区或独立知识库。
6. 补齐合法运行资源后，进行 APK、真实云服务、目标手机的语音、后台、锁屏和数字人口型验收。

构建资源和凭据边界见 [README](../README.md)。本次源码验证不证明付费云接口或第三方模型在设备上可用。
