# 1 优化结论与交付边界

通用底座继续采用现有 Flutter 与 Android 工程，保留已经接线的语音输入、模型对话、工具调用、TTS、DUIX 和普通播放器回退。优化集中在应用装配、通用接口、轮次状态、模块上下文、操作一致性和记忆隔离，使健康、学习及后续应用能够通过领域模块接入。

本文件是基于底座 1.0.15+16 说明形成的优化目标与工程交接方案，供底座维护者及开发 Agent 使用。现有接口依据 F1、F2；新增类型、目录和行为均为待实施设计，不代表底座已经升级，也不代表已完成源码测试。接入真实仓库后，先将本文件的改造项对应到实际代码，再逐项实施和验收。

用户已明确允许 SOE 降级。发音评测始终是可选扩展，未配置、关闭、失效或质量不合格时，常规对话与领域业务继续运行。基础升级不以腾讯账号、输入音频旁路或真实评测结果为前置。

## 本轮优先级

| 优先级 | 改造范围 | 完成后的行为 |
| --- | --- | --- |
| 先做 | 统一应用装配和领域隔离 | 新应用注册模块即可接入，通用层不增加健康或学习分支 |
| 先做 | 类型化事件和取消语义 | 打断、失败、重试与迟到回调有明确归属 |
| 先做 | 模块上下文与工具执行 | 能处理跨轮指令；真实业务状态由领域工具查询 |
| 先做 | 兼容迁移和数据保护 | 原健康版与底座版继续工作，历史记录不丢失 |
| 按需接入 | 输入音频观察与 SOE | 同源音频供可选分析使用，不阻塞主对话 |
| 后续优化 | 真正流式 LLM 和 TTS、大规模检索 | 依据实测延迟与容量瓶颈逐项替换提供方 |

整体采取逐步替换：先增加端口与兼容适配器，再迁移调用点。独立 SDK 发布、多进程插件体系和跨平台全面重构不属于这一轮交付。Flutter 官方也建议按职责区分界面与数据、使用抽象仓储和可替换假服务，并明确架构建议需要按实际项目调整。[R1]

# 2 现状中需要解决的问题

| 当前文档明确的边界 | 本次优化 | 依据 |
| --- | --- | --- |
| AppEdition 只有布尔开关，两版共享部分健康代码 | 通用 AppProfile 加应用级装配；健康逻辑移到领域模块 | F1 第 1 节；F2 第 1 节 |
| DigitalHumanNotifier 同时连接输入、记忆、模块、模型和播放 | 提取 ConversationRuntime，Notifier 负责界面状态映射 | F1 第 3 节；F2 第 2 节 |
| ASR、LLM 和 TTS 多为具体服务类 | 用窄接口封装现有实现，提供能力描述和统一错误 | F1 第 4 节 |
| matches 只看本轮输入 | 增加有边界的模块上下文和不可变焦点快照 | F1 第 2 节 |
| 通用层没有事务、待确认表或通用撤销机制 | 底座统一执行协议，领域保存动作与业务事务 | F1 第 2 节 |
| 状态以多个布尔量暴露，公共方法主要返回 Future<void> | 分维度状态加带标识的事件，不把 Future 完成当成功 | F1 第 3 节 |
| RAG 偏向个人记录，候选最多最近更新的 500 份 | 记忆分区、版本过滤与可替换候选召回 | F1 第 5 节；F2 第 4 节 |
| 数据库仍包含健康表，旧记忆缺少可靠冲突仲裁 | 领域接管迁移职责，原表先保留；记忆补来源与状态 | F1 第 5 节 |
| DUIX 部分低层调用吞异常，动作入口存在空实现 | 能力按实际声明，播放与动作返回明确结果 | F1 第 6 节 |

文档没有公开输入 PCM 订阅接口，DUIX playPcm 属于播放入口。实现音频分析前必须在实际用户输入处补旁路；不能用数字人输出音频作为用户发音证据。云接口、目标语言识别质量、锁屏和口型仍按真实设备验证，不由架构图代替实测。

# 3 通用层与应用层的边界

## 通用层负责的内容

Foundation Core 负责会话生命周期、轮次标识、能力描述、模块选择机制、工具执行协议、通用记忆接口和事件。Speech 与 Avatar 适配层负责音频、识别、合成、渲染和原生生命周期。Flutter 层负责 Provider 装配、界面状态映射与通用控件。

领域模块负责真实业务数据、查询和命令、操作授权政策、知识来源、上下文贡献以及自己的迁移。应用壳负责入口、路由、包名、资源和所装配的模块。通用核心不得直接引用 FitnessAssistantModule、StudyAssistantModule、训练表、复习算法或考试规则。

## 目标目录

以下为目标结构，不是现有目录清单。可先在同一仓库通过目录和导入规则实现边界，确认多个应用复用后再提取 Dart 或 Flutter 包。

```text
lib/foundation/core/
lib/foundation/contracts/
lib/foundation/flutter/
lib/foundation/adapters/legacy/
lib/foundation/adapters/speech/
lib/foundation/adapters/avatar/
lib/foundation/adapters/memory/
lib/foundation/extensions/
lib/apps/foundation/
lib/apps/health/
lib/apps/study/
lib/domains/fitness/
lib/domains/study/
```

Core 与 Contracts 可在纯 Dart 测试中运行，不创建 PlatformView，不引用 Flutter Widget、Riverpod 或 Android Channel。Riverpod 保留在 Flutter 适配与应用装配层。领域数据层使用所属仓储，界面不能跨层写表。

## AppProfile

新增 AppProfile，包含 profile_id、data_namespace、模块工厂、路由贡献、资源清单和能力策略。使用类型明确的字段与编译期注册，不从任意远端文本加载代码。

旧的 foundation 与 health 入口由兼容解析器生成对应 Profile；新学习版生成 study Profile。原包名、数据库路径与 Channel 注册保持不变。AppEdition 的枚举或旧布尔开关只作为应用入口的兼容配置，不再让通用核心识别健康或学习。

配置冲突时明确失败。不能把 study flavor、health 入口和 foundation 标志混合后继续运行。删除或关闭领域模块不等于删除它的数据；模块重装配后的数据恢复按显式迁移政策处理。

# 4 通用能力端口

以下签名表达目标协议，属于待开发接口摘要。具体 SDK、包版本和已有参数在读取源码后固定，接口实现不得编造底座未提供的能力。

| 端口 | 目标方法或对象 | 约束 |
| --- | --- | --- |
| ConversationRuntime | submitText、startInput、finishInput、stopOutput、endSession、events | 一次会话只有一个对话控制方 |
| SpeechInputPort | start、finish、cancel；InputSession 与 InputEvent | 区分单次录音和持续通话，声明实际语言与输入模式 |
| DialogEnginePort | runTurn(request, onTool, cancellation) | 一次只由一个引擎拥有工具循环 |
| SpeechSynthesisPort | synthesize、cancel；SpeechAsset 或音频事件 | 声明完整音频或真实流式输出能力 |
| AvatarPort | attach、play、stop、setExpression、detach | 返回结果，不支持的动作明确 unsupported |
| ContextProvider | queryContext(request) | 返回来源、范围、版本与新鲜度 |
| ToolGateway | execute、queryOperation、decide | 校验与路由统一，事务仍由领域提交 |
| AudioObservationRegistry | subscribe、unsubscribe、capabilities | 可选只读旁路，有界且不反压采集 |

## 先包装现有对话循环

第一阶段以 LegacyDialogEngineAdapter 包装现有 LlmService.sendWithTools，保留其工具轮次上限、消息构造与 onTool 调用。ConversationRuntime 只调度这一个引擎，不能再在外面启动第二层工具循环。

后续若拆分单次模型请求，可以新增 LlmPort 与 DefaultDialogEngine，由后者独占工具循环，并替换整个 LegacyDialogEngineAdapter。两个引擎不能同时接管同一轮。当前 stream:false 的请求返回 TextCompleted，不能把整个回答拆成字符后宣称已经实现网络流式。

## 能力和错误

CapabilitySnapshot 包含 capability_id、配置状态、运行状态、输入与输出格式、是否支持取消、是否流式、提供方版本及限制。配置为开启但设备或服务不可用时，运行状态仍可为 unavailable。

统一错误对象包含 code、source、retryable、safe_message、correlation_id 和可选 operation_id。错误至少区分用户取消、权限拒绝、配置缺失、网络失败、超时、服务限流、格式不支持和内部失败。用户取消不计为提供方故障；业务拒绝不能作为网络错误自动重试。

对外异步方法先返回受理结果，最终成功由事件或可查询回执确认。旧 Future<void> 接口可以保留给原界面调用，但由新的适配层映射执行结果，不能仅根据 Future 正常结束填入 success。

# 5 会话状态 事件与取消

## 分维度状态

会话状态分为 Session、Input、Response 和 Output 四个维度。持续通话时可以一边监听用户打断，一边播放当前输出，所以不能用一个互斥枚举代替所有状态。

| 维度 | 目标状态示例 | 归属 |
| --- | --- | --- |
| Session | idle、active、paused、ended | 会话是否存在及是否可接收新操作 |
| Input | idle、capturing、recognizing、failed | 用户输入通道 |
| Response | idle、thinking、tool_running、ready、failed | 本轮回复与工具执行 |
| Output | idle、synthesizing、playing、interrupted、failed | 合成、播放与数字人呈现 |

可选分析任务有独立状态，不进入 Response 的必需依赖。DigitalHumanNotifier 逐步降为这些状态的界面投影，兼容原有 isRecording、isProcessing、isSpeaking 等字段。

## 事件标识

FoundationEvent 具有 event_id、schema_version、session_id、session_epoch、turn_id、operation_id、utterance_id、output_generation、发生时间与负载；不适用的标识可为空，但不能用最后一轮的全局变量补填。

输入开始即生成 utterance_id 和焦点快照引用；日会话 ID 不能代替语段 ID。基础事件包括 InputStarted、InputFinalized、TurnStarted、ToolAccepted、ToolCommitted、ToolFailed、OutputStarted、OutputFinished、OutputInterrupted 和 SessionEnded。

序号在所属事件流内递增。持久业务事件按 event_id 幂等消费；实时 UI 事件可以不持久化，但重启后必须能从领域仓储和操作回执恢复实际状态。

## 取消的提交边界

stopOutput 取消当前生成或播报资格并提升 output_generation；endSession 使会话接收新输入和新的工具调用失效。关闭整个会话时终止相关任务与订阅，清理资源。

业务写入以领域事务提交点为边界。取消与提交在同一领域命令调度器内仲裁；若取消先被接受，拒绝继续提交；若提交已成功，保留操作及回执，停止过期播报，不自动回滚。不能用界面点击时间判断并发结果。结果不明时先 queryOperation，不对可能已成功的写操作盲目重试。

迟到的模型、TTS 或原生回调只有与当前 session_epoch 和 output_generation 匹配时才能更新现时输出。评测代次与输出代次分开：打断数字人不应抹掉用户已经完成的练习记录。

# 6 模块上下文与工具执行

## 模块选择

新增 ModuleContextResolver，结合本轮文字、应用允许模块、显式领域入口、活动任务、有效焦点和待确认动作选择模块。普通闲聊保留原有按需选择；跨轮学习或健康任务使用受限上下文，不要求用户每句重复领域关键词。

DomainContext 只保存通用引用：namespace、EntityRef、task_ref、focus_snapshot_ref、proposal_ref、revision 和有效范围。EntityRef 由命名空间、类型、对象 ID 与版本组成，Core 不定义 word_id、训练组数或考试分值。

学习模块据此解释“这个词”，健康模块据此解释“刚才那组”。焦点在用户开始输入时冻结；新回包不能修改已开始的指令指代。领域退出、任务结束、会话取消或引用过期后，相关作用域失效。多个对象或多个待确认动作同样合理时，澄清一次具体目标。

## 兼容 AssistantModule

保留原 AssistantModule 契约，由 LegacyAssistantModuleAdapter 提供 ModuleDescriptor 和结果适配。新模块可提供上下文感知选择与 ToolSpec；旧模块继续使用 matches(text)。模块 ID 与工具名重复仍在装配时拒绝。

ToolSpec 至少定义名称、参数与结果 schema、读写属性、授权策略、幂等和撤销能力、模式限制及版本。工具暴露与执行使用同一选择快照；执行前再次验证当前领域版本和实际权限。工具文档与 schema 从同一契约生成或校验。

旧 Map 结果由各工具的明确解码器转换。不得因为没有 error 字段就认定业务提交成功；无法判断时标记 legacy_unclassified 或 unknown，并按领域查询实际结果。afterTool 与 afterAction 保持原通知语义，不承担重复写入。

## 授权与操作回执

底座提供统一政策入口，领域决定具体规则。健康模块保留现有待确认流程。学习模块可明确列举“指定目标加入复习”等已授权、可撤销操作，校验后直接执行。模型声称“这是低风险操作”不能改变代码策略。

写入由领域在同一事务中保存业务变更、command_id、operation_id 和回执。同 ID 同负载重试返回原结果，同 ID 不同负载返回冲突；超出预期版本或授权范围时不静默覆盖。UI 和 Agent 重试同一命令须沿用原 command_id；不同意图不能仅凭相同文字被合并。

CommandReceipt 包含 status、commit_state、operation_id、affected_refs、revision、undo_scope 与同步状态。commit_state 区分 none、pending、committed 和 unknown。已保存、已同步、已安排或已完成分别报告，Agent 必须依据回执说明结果。

通用层不新建一套绕过领域事务的业务动作表。若沿用旧 decide(int actionId)，领域持久化包含数据空间、module_id、旧整数 ID 与稳定 proposal_id 的映射。不同模块的同号动作不得混淆；重启后按有效期和原值校验继续处理已有待确认单。

# 7 音频与可选分析扩展

## 音频资源只有一个管理入口

AudioCoordinator 管理麦克风所有者、前景播放所有者和路由状态。现有输入服务先由兼容适配器接入，保留 VAD 和持续通话行为；没有必要为旁路另开一套录音。切换引擎时先结束旧输入句柄并确认释放，再启用新输入。

语音合成、示范音频、录音回放与数字人 PCM 播放均领取 playback_id。播放停止、来电或路由变化同步通知呈现层；DUIX 视图卸载时按现有机制回退普通播放器。数字人未挂载不等于整个会话结束。

## 只读观察能力

AudioObservationRegistry 提供用户音频观察接口。AudioFrame 包含 source=user_microphone、capture_id、utterance_id、sequence、format、单调时间偏移及只读字节。观察者不能修改或持有可被采集器复用的可变缓冲区。

观察者队列有容量上限，并在取消、会话结束或引擎切换时解除订阅。溢出后标记对应分析输入不完整，停止对残缺数据作确定结论；主识别继续。上传、转码和重试不得占用采集主路径。

## SOE 的装配位置

通用底座只提供 AudioAnalysisExtension 的生命周期和能力接口；腾讯适配器位于可选集成层，发音纠错策略与复习计划位于学习领域。底座不内置腾讯评分规则，也不内置 FSRS。

默认装配 DisabledAnalysisExtension。关闭时不连接、不上传、不缓存等待未来自动补传的评测队列。当前识别引擎无法提供同源输入时返回 unsupported，常规语音路径继续。启用后结果通过事件交给所属领域，不能直接插入另一个 Agent 回复或 TTS 播报。

Android 前台麦克风服务涉及服务类型、录音授权和 while-in-use 启动限制。通话页启动、后台延续和系统重新启动是不同场景，应按实际 targetSdk、系统版本和设备分别验收；不能用最低 SDK 版本推断全部行为。[R2]

# 8 记忆隔离与检索优化

## 三种信息分开管理

通用记忆保存用户明确偏好与跨领域会话事实；领域仓储保存训练记录、学习进度等业务真相；内容知识保存专业资料和版本。它们可以通过接口关联，但聊天摘要、模型标签和向量结果不能覆盖已提交的领域事实。

记忆记录增加 record_id、namespace、subject_id、kind、source_ref、observed_at、revision、status 和可选 expires_at。用户明确纠正的信息形成新版本并使旧记录失效；模型推测不能覆盖已确认事实。来源不足的冲突保留为待核查状态。

## 上下文的所有入口都要过滤

领域范围和数据权限必须覆盖画像、最近消息、摘要、事实查询及 RAG，不能只过滤最后的向量检索结果。历史会话混合多个领域时，保存原文不变，提供上下文时按范围使用有来源的相关片段。

旧记录不能全部迁为 global。健康专属记录进入 fitness；明确通用的偏好可以进入通用范围；无法判断的记录保留在原应用的 legacy 范围。原健康版经兼容读取策略继续使用自己的旧记录，新的学习版不会自动继承它们。

## 索引与真相一致

记录更新、撤回或过期时，先在真相表写状态及版本，并在同一事务写入索引更新任务。检索命中在返回前复核记录状态、namespace 和 revision，避免后台索引尚未完成时返回已撤回内容。

Embedding 与索引修复允许后台重试；失败不会让基础聊天和已保存业务数据消失。原有只取最近更新 500 份候选的方式改为可替换的候选召回接口，从有权限的全部文档范围进行适当检索，再限制候选数量和做向量排序。实际索引实现依据数据量与现有 SQLite 能力选定，不要求首版引入独立向量服务。

## 对话等待路径

建立各阶段耗时记录，先确认输入、上下文、模型、工具、TTS 和播放分别耗时多少。将非关键摘要、Embedding 和索引更新放在回复后的可恢复任务中；当前用户指令要求的业务写入仍须先提交再报告完成。

上下文检索设置独立时间预算，超时使用有效的已有上下文或明确无结果。后续是否升级真正流式模型与合成，以首段可播放语音时间和整体体验实测决定，不为了接口名称变化重写整条语音链。

# 9 配置 诊断与故障恢复

## 配置边界

AppProfile、用户偏好、供应商配置和凭据分开。Profile 决定装配，偏好决定用户选择，CapabilitySnapshot 说明当前实际可用能力。更换提供方通过适配器工厂解析，不让业务模块依据模型名称分支。

现有 BuildConfig 和 getApiKey 方式保留为明确的开发兼容路径；公开发行的云调用使用后端代理或受限短期凭据，并逐个供应商验收。长期密钥不进入导出文件、日志、RAG 或模型上下文。不能只修改配置字段名称就声称已完成凭据迁移。[F1 第 6 至 7 节]

## 诊断结果

每轮记录 trace_id、提供方与配置版本、阶段耗时、取消原因、工具次数、结果类型和资源释放状态。默认诊断日志不包含原始音频、完整用户资料或密钥。界面可展示“语音识别不可用”“数字人未挂载”“发音评测关闭”等具体状态。

权限、网络、服务、输入质量和业务拒绝分别统计。SOE 关闭不能计为评测失败；用户取消不能计为接口超时；模型识别到一个词不能计为发音合格。

进程重启后读取已提交会话和领域回执，未决操作先查询结果。旧输入、输出和观察者句柄全部失效，不擅自打开麦克风或重传历史录音。底座负责恢复机制，具体任务是否继续由所属领域决定。

# 10 兼容迁移与开发顺序

## 数据迁移政策

第一阶段只迁移代码职责，不删除、不搬迁现有健康数据表。DatabaseMigrationRegistry 接管全局迁移协调，各领域注册自己拥有的迁移，兼容既有 schema 版本、表名、执行顺序与事务边界。领域未装配不能触发删表。

先校验旧健康库、旧底座库与新安装三种情况。迁移须可重入，中断后从检查点恢复；失败不能标记新 schema 已完成。将来如果确实拆物理数据库，再单独设计备份、复制校验、写入暂停和切换记录，这轮不附带搬库。

原包名、原生 Channel、DUIX 模型路径和 Provider 覆盖关系先保持兼容。新命名只用于新增类和新应用配置，不批量替换字符串破坏原生通信。

## 按可回归阶段实施

| 阶段 | 修改范围 | 进入下一阶段的条件 |
| --- | --- | --- |
| O0 建立基线 | 读取真实源码、指令文件和锁文件；记录当前入口与已有测试 | 能复现当前构建与主要流程，记录既有失败 |
| O1 契约与适配 | AppProfile、基础事件、能力与错误类型；旧模块和对话引擎适配 | 原入口不改调用方式仍可工作 |
| O2 运行时分离 | ConversationRuntime、Notifier 状态映射、取消与资源句柄 | 打断与迟到回调测试通过，无双重工具循环 |
| O3 领域控制 | 上下文解析、ToolSpec、真实回执、政策与旧动作映射 | 健康确认保留，学习明确操作可直达且可撤销 |
| O4 数据边界 | 领域迁移注册、记忆 namespace、来源与索引状态过滤 | 旧数据可读取，领域不会互相污染 |
| O5 可选音频 | 只读观察、队列隔离、扩展生命周期；可选择接 SOE | 关闭或失败不影响基础链，音频所有权清楚 |
| O6 交付回归 | 两个原应用与新学习版集成，更新接口实况文档 | 声明的能力均有对应证据，未启用项单独记录 |

O5 不作为 O1 至 O4 的前置。每阶段形成可独立审查的变更；共享契约和数据库迁移先统一，再并行处理互不修改同一核心文件的适配器。遇到真实仓库与文档不同，修正适配方案并记录差异，不能按猜测制造兼容层。

## 与学习版架构的关系

| 学习版已有设计 | 优化后归属 | 对学习模块的影响 |
| --- | --- | --- |
| FoundationTurnBridge | 通用事件流的学习适配器 | 保留学习会话与底座轮次映射 |
| StudyContextRouter | 通用 ModuleContextResolver 加学习上下文贡献 | 词汇与复习指代仍由学习领域解析 |
| ConversationPort | ConversationRuntime 的门面或兼容接口 | 学习页面不直接依赖 Notifier 内部逻辑 |
| SpeechEvaluationPort | 可选音频扩展的学习侧评测端口 | SOE 继续可关闭；评分和练习策略留在学习层 |
| AppEdition 三种版本 | 应用入口到 AppProfile 的映射 | Core 不硬编码 foundation、health 或 study |

# 11 验收场景

以下是待实施的验收要求，不是本轮已执行的测试结果。自动化测试以可控假服务验证时序、数据和接口；真实服务与设备测试分别验证实际识别、合成、播放和后台行为。

| 编号 | 场景 | 通过标准 |
| --- | --- | --- |
| F01 | 原健康与底座入口 | 原包名、数据路径、Provider 与 Channel 继续正确 |
| F02 | Profile 配置冲突 | 明确失败，不静默装配另一应用 |
| F03 | 未注册学习模块 | 通用 Core 可运行，不引用学习或健康表 |
| F04 | 新旧模块混装 | 旧 matches 和提案钩子正常，重复 ID 或工具名被拒绝 |
| F05 | 跨轮说这个或刚才那组 | 使用输入开始时的焦点；目标不唯一时澄清 |
| F06 | 多个模块有相同整数动作 ID | 按数据空间和模块映射，不确认错单 |
| F07 | 重启后确认旧动作 | 映射可恢复；检查有效期、原值和实际授权 |
| F08 | 健康确认与学习直达 | 原健康确认保留；仅明确白名单学习命令直达 |
| F09 | UI 与语音重试同一命令 | 沿用同一 command_id，只提交一次并返回原回执 |
| F10 | 事务成功后网络或生成失败 | 不重复写入，不错误回滚，可查真实提交结果 |
| F11 | 提交前取消与提交后取消 | 提交边界清楚，已提交事实保留，旧播报停止 |
| F12 | A 轮迟到回调覆盖 B 轮 | 被 epoch 和 generation 拦截，不污染新状态 |
| F13 | 对话引擎迁移 | 每轮只有一个工具循环，旧次数上限不意外放大 |
| F14 | 完整返回与真实流式 | 能力声明匹配实际网络行为，不伪造流式指标 |
| F15 | SOE 关闭 失败或不支持 | 无多余上传或历史补传，常规对话与业务继续 |
| F16 | 音频观察者慢或崩溃 | 不抢麦、不改共享数据、不反压主采集 |
| F17 | 切页 视图卸载 蓝牙与来电 | 单播放所有者，资源释放，普通播放器回退正确 |
| F18 | 后台 锁屏 权限拒绝与进程重启 | 明确状态，不私自恢复录音，按目标设备验证 |
| F19 | 旧库和迁移中断 | 记录、关联与偏好保留；重试无副作用 |
| F20 | 旧记忆归属未知 | 保留原应用 legacy 范围，不直接变为通用事实 |
| F21 | 画像 摘要 最近消息与 RAG | 所有上下文入口均按领域和权限过滤 |
| F22 | 记忆撤回但索引更新失败 | 旧索引不能返回已失效记录，更新任务可恢复 |
| F23 | 模型推测与用户纠正冲突 | 已确认事实不被猜测覆盖，来源和修订可查 |
| F24 | 日志与凭据检查 | 不导出密钥；各供应商迁移结果分别记录 |

交付时逐项记录通过、失败或未启用，并附可复现条件。假服务通过不代表云服务和真机通过；SOE 未启用不妨碍基础分组放行，也不计为发音评测已通过。

# 12 开发 Agent 交接要求

执行目标是把底座改为可重复装配领域模块的通用运行时，保留既有应用行为。先读取仓库的 AGENTS.md、实际分支和未提交变更，建立隔离开发环境；不得覆盖用户在做的改动，也不得把本文件的目标类型假定为源码中已经存在。

优先从 O0 至 O1 开始，每次变更报告实际修改文件、解决的问题、验证结果及剩余限制。真实业务事务与迁移使用有意义的测试，不编写只复述实现的测试。未取得目标手机或云服务时，保留相应未验证状态，不声称已经通过。

用户已经授权优化方向。与授权范围一致且可逆的实现选择可以推进；只有缺少源码、服务访问或确需用户决定的目标冲突时提出具体阻塞。不得为学习版每条明确收录命令增加无必要的二次确认，也不得放宽健康版已有业务确认。

本轮交接完成后，实际源码接入仍是修改和构建的必要输入。可提供底座源码压缩包，或能访问的仓库地址与目标分支；不需要提供私钥或把供应商密钥放进文档。现有两份接口实况文档应在代码变更和验证完成后更新，继续区分现有、待验收和建议。

# 13 参考依据

F1 数字人底座接口说明书 FOUNDATION_INTERFACES.zh-CN.md。用户提供，日期 2026 年 10 月 5 日，依据源码版本 1.0.15+16。

F2 数字人底座说明 FOUNDATION_OVERVIEW.zh-CN.md。用户提供，日期 2026 年 10 月 5 日，依据 ai-secretary-exercise-build 版本 1.0.15+16。

R1 Flutter 官方 Architecture recommendations and resources。用于职责分离、抽象仓储、依赖注入和假服务验证的原则；本文件不要求改用官方示例中的状态管理包。
https://docs.flutter.dev/app-architecture/recommendations

R2 Android 官方 Foreground service types。用于麦克风前台服务、授权和启动限制；实际行为按项目 targetSdk 与设备验证。页面标注最近更新为 2026 年 10 月 1 日。
https://developer.android.com/develop/background-work/services/fgs/service-types
