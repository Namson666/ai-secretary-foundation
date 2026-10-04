# 数字人底座优化范围与验证

> 2026-10-05。本次从公开底座提交 `ed823832aa92ac45729bbf6ba99bee48e45c010c` 开始实施，保持现有 Flutter/Riverpod、ASR → LLM/工具 → TTS → DUIX 路径。这里记录已实现的第一阶段源码改造；完整设计中的后续目标不等于已上线功能。

## 1. 已实现的改动

| 范围 | 解决的问题与当前行为 | 主要实现 |
| --- | --- | --- |
| 应用配置 | 新增 `AppProfile` 和不可变模块允许列表；装配及输入开始时拒绝未注册模块 ID | [AppProfile](../lib/core/app_profile.dart) · [Providers](../lib/providers/assistant_modules_provider.dart) |
| 页面对象引用 | 新增可过期上下文与稳定实体引用。文字、单次录音开始、连续通话 speech-start 捕获应用/注册表/页面；缺失 speech-start 时不推断屏幕对象 | [上下文](../lib/core/assistant/assistant_context.dart) · [输入快照](../lib/providers/assistant_modules_provider.dart) |
| 本轮工具一致性 | 注册时冻结 schema；本轮 `selection` 固定工具、路由、指导和上下文；调用前重查上下文有效期。旧继承模块及静态入口仍兼容 | [模块注册表](../lib/core/assistant/assistant_module.dart) |
| 聊天异步归属 | 切换/清空会话、历史查询、索引和流回调检查所属请求，旧工作不覆盖较新界面；已提交数据保留 | [聊天 Provider](../lib/providers/chat_provider.dart) |
| 语音异步归属 | 单次录音固定使用启动时 ASR 引擎；通话与录音共享清理队列，旧清理完成后才开始新采集；新语音开始使旧输出失效 | [数字人 Provider](../lib/providers/digital_human_provider.dart) |
| 原生回调与音频 | 通知注册返回只解除自身的函数；旧视图播放失败只停止原视图 Channel，保留原播放异常 | [前台服务](../lib/services/call_foreground_service.dart) · [音频桥](../lib/services/avatar_audio_bridge.dart) |
| 同 key 事实 | 查询与合并置于事务；用户明确来源不被 AI 提取覆盖，后续用户更正可写入；矛盾新值不继承旧值置信度 | [数据库](../lib/core/database/database_helper.dart) |
| 画像与向量投影 | 从数据库实际接受的事实生成画像和索引，网络 embedding 不占数据库事务；消除单事实重复画像 embedding | [记忆服务](../lib/services/memory_service.dart) |
| RAG 当前性 | 对五类已管理来源检查当前内容/元数据，memory 检查有效期；索引前及 embedding 后写入前复查；失效源不占候选预算，修复统计反映实际结果 | [RAG 服务](../lib/services/rag_service.dart) |

用户说“把这个加入复习”时，底座能把输入开始时的对象引用传给领域工具。实际复习记录、计划变更、考试成绩等仍需学习模块的仓储和工具实现；本次没有创建这些业务功能。

## 2. 保留的兼容边界

Android 包名、MethodChannel 名称、PCM 格式、`ai_secretary.db`、schema 6、原有表及迁移门槛保持不变。`AssistantModule.invoke` 和原确认钩子继续兼容；新增 `invokeWithContext` 默认转调原方法。`extends AssistantModule` 的旧模块可继承默认实现，直接 `implements AssistantModule` 的外部类需补齐新增成员。

健康模块的待确认机制保留；若后续输入所属应用已排除原模块，或注册表已撤下该模块，不执行旧待确认单。明确且可逆的学习写入可以由领域工具直接执行，不要求所有写操作统一二次确认。

`AvatarAudioBridge.play` 的 `false` 与异常仍有区别：未挂载/非前台可返回 `false`，供未取消的 TTS 使用普通播放器；非法 PCM 和原生播放错误继续传播。未来 SOE 不可用时允许跳过评测，不意味着忽略 ASR、TTS 或数字人自身的错误。

## 3. 本次未完成的架构目标

| 后续工作 | 当前边界 |
| --- | --- |
| 数据库领域隔离与迁移 | `AppProfile.dataNamespace` 只验证页面上下文归属，不隔离旧 SQLite 读写。没有 namespace 表迁移、物理文件移动或历史重复 key 清理。 |
| 完整记忆删除传播 | 每份 RAG 投影只与自己的源记录核对；不会级联删除旧聊天、摘要或画像中其他记录对同一事实的提及。 |
| 全库向量检索 | 默认仍只收集最近 500 个通过来源校验的候选，之后排序；不是对全库全部有效向量求最优结果。 |
| 自定义来源证明 | 未知扩展 `source_type` 保持原有兼容行为，不由底座证明其原始来源，也不自动增加 SQLite 依赖。 |
| 通用业务动作账本 | 没有通用提交回执、持久业务事务账本、outbox、自动重试队列或跨设备同步。领域工具需要定义实际提交结果。 |
| 独立 ConversationRuntime | 保留两个现有 Notifier 与一套 LLM 工具循环，尚未完成对话编排的整体抽取。 |
| 供应商中立端口 | LLM、ASR、TTS、DUIX 仍主要为具体实现；未提供统一可热插拔服务/渲染器接口。 |
| SOE 与发音评测 | 没有 SOE SDK/适配器、音频观察旁路或评分队列。后续必须可关闭、异步返回、故障时不等待评分。 |
| 学习产品功能 | 没有词库、学习计划、遗忘调度、考试、纠音练习或学习 Agent 工具的领域实现。 |

## 4. 验证结果

整合验证使用 **Flutter 3.47.6 stable / Dart 3.13.5**。执行原版基线与修改后的 foundation 模式测试：

| 验证 | 原版基线 | 本轮整合结果 |
| --- | --- | --- |
| `flutter test --dart-define=FOUNDATION_APP=true --no-pub` | 57 项通过 | **125 项全部通过** |
| `flutter analyze --no-pub` | 1 条既有 `unawaited_return_in_try_block` 提示 | **No issues found** |

上述结果包含审查中新增的八项回归：快速重拨、通话转录音、录音转通话、语速保存期间开始新语音、provider 重建后旧历史列表查询完成、录音收尾时再次录音、取消后识别器仍在收尾时重新采集，以及排队中的录音提前松开。已有的准备期松开测试也补充了不调用 `finish` 的验证。原版 57 项基础上共增加 68 项测试。最终提交以 PR 为准，云服务或真机状态不计入通过结果。

主要回归场景对应文件：

| 场景 | 测试 |
| --- | --- |
| 注册表被外部修改、重复工具名、允许列表、过期/跨应用上下文、旧模块兼容 | [注册表](../test/assistant_module_registry_test.dart) · [上下文](../test/assistant_context_test.dart) · [旧模块](../test/assistant_module_compatibility_test.dart) |
| 输入后页面焦点变化、文字及语音保持原对象、缺失 speech-start | [上下文集成](../test/assistant_context_integration_test.dart) |
| 清空/切换后的延迟回调、旧历史、语速/ASR/播报取消、通知所有者释放 | [聊天生命周期](../test/chat_request_lifecycle_test.dart) · [语音生命周期](../test/digital_human_lifecycle_test.dart) · [通知回调](../test/call_foreground_service_test.dart) |
| 明确事实与 AI 冲突、并发同 key、实际记录投影、失效来源、延迟 embedding、修复失败、外部索引兼容 | [记忆一致性](../test/memory_consistency_test.dart) · [RAG 一致性](../test/rag_consistency_test.dart) · [扩展索引](../test/rag_vector_extension_test.dart) |
| 旧视图迟到失败不停止新视图、播放错误保留 | [TTS/Avatar 桥](../test/tts_avatar_bridge_test.dart) |

复现命令：

```bash
flutter --version
flutter pub get
flutter analyze --no-pub
flutter test --dart-define=FOUNDATION_APP=true --no-pub
```

Linux 主机执行 SQLite FFI 测试时，需要动态链接器能够找到 `libsqlite3.so`。这属于主机测试环境，不要求应用为测试改用其他数据库实现。

本次没有新增生产依赖。`pubspec.lock` 保留该 Flutter/Dart 工具链解析的六项传递依赖更新：`matcher`、`meta`、`test`、`test_api`、`test_core`、`vector_math`。这些变动属于验证工具链对齐，不计作产品功能。

## 5. 运行验收边界

当前验证使用受控异步服务、MethodChannel 替身与真实本地 SQLite，覆盖源码行为。公开仓库仍缺少 DUIX SDK/模型、本地 ASR 权重、私有凭据和签名资源，本次未构建完整 APK，也未验证真实云调用、设备延迟、锁屏持续录音或数字人口型。

学习应用可以从现有上下文与工具接口继续接入独立领域仓储，先走通“显示单词 → 用户明确加入复习 → 工具真实提交 → 返回记录”的一条路径，再增加异步 SOE。构建资源与命令见 [README](../README.md)，具体接口见[接口说明书](FOUNDATION_INTERFACES.zh-CN.md)。
