# 拾语 Android 实现记录

本分支承接网页确认资产，目标是实际 Flutter/Riverpod 原生学习应用。入口 `lib/main_study.dart`，独立 study flavor / com.namson.shiyu。网页原型仍独立保留，不用 WebView 包壳。未提交的进展不是最终 APK 验收。

## 有效需求 → 实现 → 验证

| 需求 | 实际实现位置 | 验证方式/当前边界 |
|---|---|---|
| 4 本真实词库、共享选词、搜索、字母批选、顺/随机与确认 | assets/study/vocabulary.json; presentation/library_page.dart | 1000/1500/1500/1500；源并集2468，加6独立例句卡2474。catalog/搜索选择 widget tests；MIT 固定来源见资产说明 |
| 词义、产出、拼写、听辨、发音技能隔离 | domain/study_models.dart; presentation/learning_page.dart | meaning/production/spelling/listening/pronunciation 独立 card_id。遮挡与先独立声明/提示分开；听辨要求单音频 owner 完整播放，阅读补练不记独立听辨 |
| SQLite 真实保存、重启与暂停/熟知/收藏 | data/sqlite_study_repository.dart | 独立 study.sqlite；原 legacy DB 不动。ffi 真实文件关闭重开 tests；未选词收藏不自动选入 |
| 个人复习、FSRS-6 | domain/review_scheduler.dart; data/fsrs_scheduler.dart | 精确锁 Dart fsrs 2.0.1，官方 FSRS-6 / 21参数。持久 card/log/model/参数/retention/evidence。Again 不保旧过期due；自动归属不由用户撤销取消 |
| 真实计划、当日预算 | domain/study_service.dart; presentation/plan_page.dart | 上海日界线；只已到期任务入默认队列，未来列在计划中；每日总量/新学减当天消耗，保守3分钟/任务。版本冲突防覆盖 |
| Agent 冻结对象→贡献保存→安排→撤销 | application/study_tools.dart; data/study_review_storage.dart | stable runtime tool command ID；真实 finalText 授权；事务末 cancellation lease；receipt/outbox 原子提交；撤销仅本贡献，保历史/自动任务 |
| 双模式真实语音/数字人 | study_runtime owner; presentation/coach_page.dart | 全局 runtime；hold 取消/全屏/静音等由 native 测试；实际设备 API/ASR/DUIX 与 APK 验收记录由 native owner 补 |
| 考试冻结范围与分阶段评分 | data/study_exam_storage.dart; presentation/exam_page.dart | active → submitted → graded → published；未发布不暴露参考答案/成绩，进行中不允许查词/普通练习；当前真实客观中→英拼写题型 |
| 真实统计与技能弱项 | domain/study_analytics.dart; presentation/statistics_page.dart | 实际尝试/独立/提示/忘记，真实FSRS状态计算预测；清楚标模型估计，不伪装观察到的记忆概率或长期掌握 |
| 设置、备份/恢复 | presentation/profile_page.dart; data/study_backup_validation.dart | 正式复制备份、粘贴预览与确认恢复；schema/namespace/枚举/类型/JSON/引用校验后原子替换；非法备份保原库 |
| SOE异步增强 | capability disabled | 无key，不阻断基础学习；发音自练不产生评测分数。真实SOE适配/质量检验等待用户资源，不声称已实现 |

## 边界

本机 API 密钥、DUIX 私有 SDK、数字人/ASR 大型模型不进入 Git。CI 只跑可重复代码、领域/界面和公开词库检查；本机真实模型 APK/模拟机集成须另外记录，不拿静态分析或 APK 生成代替安装运行验收。

目前考试评分为冻结的 exact-match-v1 拼写规则，不冒充开放口语/作文考试或综合英语能力评估。英语/中文语音识别采用 MiniMax 云端 asr-1.0，需要网络；不会把底座现有中文离线模型称为英语识别。Flutter官方pubspec flavor assets（https://docs.flutter.dev/tools/pubspec）用于隔离：foundation保留原ASR权重，study仅打包英语学习轻量资产。英文参考朗读需实际在线音频服务可用；失败/静音显示不可用并可转阅读补练。SOE off 只记录自练完成，ASR 识别文本不是发音分数。

## 当前源码验证

2026-10-05，native owner 在冷启动 deadline 修复后完整 Flutter 测试实跑184通过、2个底座已有跳过项、0失败、退出码0（35秒）；此前学习 owner 全量183通过，此次增加1项 Avatar deadline 综合回归。包含真实 SQLite、学习/考试/备份界面、领域取消与幂等、语音 owner、工具播放、回执卡正式撤销元数据，以及备份 FSRS 卡步骤损坏变体（字符串、重学空步骤、负值、越界与 review 非空步骤）。全仓 `dart analyze` 无问题、退出码0；Avatar修复3文件另经native分析0问题；`git diff --check` 通过；网页保留资产的26条测试通过。此处是源码测试结果，未将它们当作模拟机验收。

本机 `flutter analyze` 的 analysis server 曾出现 LSP initialize JSON 截断异常；使用同一 Flutter SDK 的 `dart analyze` 全仓分析成功，CI 仍执行标准 Flutter 分析和完整测试。最终提交与设备结果由后续验收记录绑定具体 HEAD。

`integration_test/study_app_journey_test.dart` 准备了真实原生 SQLite 的选词→遮挡提示→保存→重开、冻结 Agent 对象→回执→安排→撤销、考试草稿恢复→提交→评分→发布三条流程。实际设备运行结果待 native owner 补记，不能将测试文件存在或 APK 生成当成安装运行验收。禁止落盘测试截图；构建产物最多两版。

设备阶段使用独立 `Shiyu_Acceptance_API34`（官方API34 ARM64镜像），合并6项入口实跑5通过、1失败：DUIX就绪→真实TTS→生产VAD→云ASR→实际录音器取消、Coach全屏/收起同一avatar及播放/静音/挂断、选词遮挡Again/SQLite重开、冻结回执安排撤销、考试草稿恢复发布均通过。LLM工具项本轮遭遇服务HTTP529，界面明确报错且没有假保存；此前真实MiniMax-M3.1调用→工具收录→下一轮撤销→原生SQLite contribution inactive闭环通过，但不能替代本次整套通过，最终release还需受控复验。

首轮DUIX旧deadline失败定位为冷解压实测62秒，而旧计时还包含平台创建前阶段；现从真实平台创建开始计时，180秒仅是冷启动容错上限。原AVD系统服务故障不计入通过证据，原userdata未改；验收以新独立AVD为准。参考PCM用于识别/播放输入验证，实际录音器生命周期已验证，未把这些等同真人讲话验收；冷初始化与热启动时长仍分别按实际记录，不用容错上限冒充启动耗时。

## 本机构建入口

已有 foundation 文档的 `lib/main_foundation.dart` / foundation flavor 构建方式保持有效；新英语产品必须明确使用独立入口和 flavor：

```sh
flutter build apk --release --flavor study -t lib/main_study.dart --target-platform android-arm64
```

该命令需要用户本机已配置的 Android/JDK、DUIX 私有资源及 MiniMax 运行配置。默认入口或仅换显示名称不能替代该产品入口。Study轻量词库与备用形象仅属于study flavor；中文离线 ASR 资源只属于foundation flavor。CI仅分析全部入口并运行可重复源码测试，不构建或上传含运行配置的APK；APK只在本地交付。
