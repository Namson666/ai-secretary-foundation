# 数字人底座说明

> Codex 整理，2026-10-05。依据 `ai-secretary-exercise-build` 源码 `1.0.15+16`；此公开仓库只含底座源码，不含健康版代码或第三方模型资源。接口逐项见 [数字人底座接口说明书](FOUNDATION_INTERFACES.zh-CN.md)。

## 1. 定位与边界

数字人底座负责数字人显示、语音输入、模型对话、语音播报、会话与记忆、通用设置和可选工具调度。健康助手是在同一源码上编译的另一个应用版本，额外装配健身模块和界面。新项目可复用底座，再装配学习等领域模块；目前采用**编译期组合**，并非在已安装 APK 中动态加载插件。

| 项目 | 底座版 | 健康版 |
| --- | --- | --- |
| 入口 | [`lib/main_foundation.dart`](../lib/main_foundation.dart) | 原工程 `lib/main.dart`，公开副本不含 |
| Android 包名 | `com.namson.ai_secretary.foundation` | `com.namson.ai_secretary` |
| 首页/设置 | 数字人首页 + 基础设置 | 数字人首页 + 健康应用界面 |
| 通用工具 | 按需选择 WebSearch | WebSearch + 按需选择健身工具 |
| 训练资源 | 不打包动作媒体 | 打包动作目录及媒体 |
| 本地数据 | 独立应用私有 SQLite/偏好 | 独立应用私有 SQLite/偏好 |

两版虽共用数据库代码，但安装后数据不自动共享。底座数据库 schema 仍包含训练表，`MemoryService` 中也保留受开关控制的训练上下文代码；因此现状是**功能组合隔离**，尚不是完全独立的领域包隔离。

## 2. 当前架构

```text
HomeScreen / 基础设置
    | 用户语音、文字、通话控制
    v
DigitalHumanNotifier  ---- SettingsNotifier / user_preferences
    |-- ASR: sherpa-onnx 本地流式；可选百炼实时；MiniMax 文件识别
    |-- MemoryService: SQLite 对话、画像、事实、摘要 + RagService
    |-- AssistantModuleRegistry: 本轮选择工具与领域指导
    |      |-- WebSearchModule（通用）
    |      `-- FitnessAssistantModule（仅健康版）
    |-- LlmService: DeepSeek / MiniMax 对话与受限工具循环
    `-- TtsService: MiniMax 语音合成
             |-- AvatarAudioBridge -> Android DUIX PlatformView
             `-- 普通音频播放器（数字人视图不可用时）

Android MainActivity: PlatformView、配置 MethodChannel、前台通话服务
```

核心接线在 [`digital_human_provider.dart`](../lib/providers/digital_human_provider.dart)、[`assistant_module.dart`](../lib/core/assistant/assistant_module.dart) 和 [`foundation_app.dart`](../lib/foundation_app.dart)。语音与文字进入同一轮处理、记忆和 TTS 路径；健康版在原工程的入口覆盖模块注册表，公开副本不包含健康模块。

## 3. 能力实况

| 能力 | 当前实现 | 验证边界 |
| --- | --- | --- |
| 数字人渲染 | Android DUIX PlatformView，当前模型资源为 `小秘`；PCM 可驱动播音/口型 | 与 DUIX 资源格式、授权绑定；不是任意视频转换接口 |
| 本地语音识别 | sherpa-onnx 模型，麦克风 PCM 流和 partial/final 回调 | 本地默认；实际速度、锁屏持续性需目标手机测试 |
| 云语音识别 | 可选百炼 Flash 实时、MiniMax 录音后识别 | 百炼识别曾由用户报告失败；MiniMax 文件模式不支持持续通话 |
| 模型对话 | 默认 `deepseek-flash`，可选部分 MiniMax/DeepSeek 模型 | 当前工具轮次 HTTP 请求为 `stream: false`，不是逐 token 实时输出 |
| 语音合成 | MiniMax `speech-2.8-hd` / `speech-2.8-turbo`，音色试听、语速和可选情绪 | TTS 当前 `stream: false`，须取得完整音频后才播放；端到端延迟与口型效果需真机验收 |
| 会话与长期记忆 | SQLite 聊天、画像、事实、摘要、向量 RAG | 向量化依赖百炼 Embedding 网络/API；无独立专业知识库 |
| 联网搜索 | 可按当前问题选择百炼 WebSearch MCP | 适配器及假服务测试存在；付费服务开通与真实检索未在本说明中验证 |
| 持续通话 | 前台服务通知支持返回/挂断；切页恢复识别 | 后台、锁屏、系统状态栏形态受 Android/厂商限制，不能仅凭代码保证 |

底座不等于“纯语言模型”：还包含 ASR、TTS、数字人、工具调用、SQLite 记忆与 Android 原生层。但它也**不是通用自主 Agent**：当前仅根据本轮文本选择模块，最多 5 轮、每轮最多 8 个工具调用，没有跨任务规划器或后台任务执行器。[工具循环](../lib/services/llm_service.dart)

## 4. 数据与知识边界

底座把原始聊天、画像、键值事实、每日会话摘要和向量文档放在应用私有 SQLite。文字对话通常带最近 16 条消息；RAG 最多从最近更新的 500 份候选索引里返回 8 份。底座和健康版的数据库文件名相同，但各自位于不同包的私有目录，不能据此推断已经共享记忆。[记忆代码](../lib/services/memory_service.dart) · [RAG 代码](../lib/services/rag_service.dart)

目前 RAG 索引的是**个人资料与活动记录**，健康版另有结构化动作目录和训练数据；没有带来源、版本、适用人群与复审日期的专业健康知识库。新项目应把“用户记忆”“领域事实/业务记录”“权威知识资料”作为三个不同数据域。不要把聊天摘要当作训练成绩、学习进度或可追溯知识证据。

现有记忆整理包括规则提取、模型 `[MEMORY: ...]` 标签、按 key 更新、对话摘要及索引修复入口；但缺少完善的冲突仲裁、来源审计、领域命名空间和自动清理。衰减函数存在但未见生产调用，向量索引与过期事实的一致性也需补强。新项目不能直接把它宣传为可靠的“无限记忆”。

## 5. 新项目复用建议

1. **保持底座薄**：首页数字人、音频、会话、模型选择、通用设置和只读搜索放在通用层；学习等领域数据、提示、工具、路由和迁移放在 `lib/features/<domain>/`。
2. **编译期装配**：新建项目入口、应用路由与 Android flavor/包名，像健康版一样覆盖 `assistantModuleRegistryProvider`。不要仅改应用名称而沿用健康版入口，否则会把健身工具和资源带入新 APK。
3. **领域数据有唯一真相源**：学习进度、错题等写入领域表；LLM 只负责意图理解与解释，读取通过工具进行。修改/删除先生成待确认单，再由用户确认并校验原始记录。
4. **先补接口隔离再扩模型**：当前 LLM/TTS/ASR/DUIX 多为具体实现类。若计划频繁更换供应商或数字人渲染器，应在项目内先抽出识别、生成、合成、渲染端口及一致的错误/取消语义；不要误以为现有 APK 已支持热插拔。
5. **记忆按领域分区**：底座保存通用偏好；学习或健康模块保存本领域事实。检索时按当前意图、权限和来源过滤，避免普通聊天自动被历史领域资料带偏。

建议的新项目结构（**设计建议，非现有文件**）：

```text
lib/main_<domain>.dart             # 新版入口与 Provider 覆盖
lib/<domain>_app.dart              # 新版路由/领域 UI
lib/features/<domain>/
  <domain>_assistant_module.dart   # 工具、选择条件、领域指导
  <domain>_tools.dart              # 参数校验、读取、待确认写入
  <domain>_repository.dart         # 领域数据库唯一读写入口
  <domain>_screens/               # 领域界面
```

## 6. 构建、授权与安全

当前底座构建命令：

```bash
flutter build apk --release --flavor foundation -t lib/main_foundation.dart --dart-define=FOUNDATION_APP=true
```

`foundation` flavor 与 `FOUNDATION_APP=true` 必须同时使用；此公开副本已将默认 flavor 改为 `foundation`。Android 最低 SDK 26。模型密钥由未纳入版本控制的 `android/local.properties` 注入 `BuildConfig`，再由 MethodChannel 供 Dart 获取；**把密钥编进 APK 不能当作安全保密方案**。公开发行前须改成后端代理或短期凭据。此源码仓库不含 DUIX SDK/模型、本地 ASR 权重或动作媒体；补齐授权资源前不能构建完整数字人 APK。[仓库说明](../README.md)

本说明仅核对源码与既有文档，没有在本次重新构建 APK，也没有重新做付费云接口或真机锁屏测试。新项目验收至少应覆盖：两版数据隔离、冷启动/设置导航、语音及文字同一会话、打断/挂断、后台与锁屏、TTS 音色与口型、工具读写确认、无领域串话、密钥不进入日志/导出文件。
