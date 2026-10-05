# 拾语 Android 实现记录

本分支承接网页确认资产，实现实际 Flutter/Riverpod 原生学习应用。入口 `lib/main_study.dart`，独立 study flavor / com.namson.shiyu。网页原型仍独立保留，不用 WebView 包壳。生产源码为 a4a140a；设备记录与后续文档提交不改变APK生产源码树。

## 有效需求 → 实现 → 验证

| 需求 | 实际实现位置 | 验证方式/当前边界 |
|---|---|---|
| 4 本真实词库、共享选词、搜索、字母批选、顺/随机与确认 | assets/study/vocabulary.json; presentation/library_page.dart | 1000/1500/1500/1500；源并集2468，加6独立例句卡2474。catalog/搜索选择 widget tests；MIT 固定来源见资产说明 |
| 词义、产出、拼写、听辨、发音技能隔离 | domain/study_models.dart; presentation/learning_page.dart | meaning/production/spelling/listening/pronunciation 独立 card_id。遮挡与先独立声明/提示分开；听辨要求单音频 owner 完整播放，阅读补练不记独立听辨 |
| SQLite 真实保存、重启与暂停/熟知/收藏 | data/sqlite_study_repository.dart | 独立 study.sqlite；原 legacy DB 不动。ffi 真实文件关闭重开 tests；未选词收藏不自动选入 |
| 个人复习、FSRS-6 | domain/review_scheduler.dart; data/fsrs_scheduler.dart | 精确锁 Dart fsrs 2.0.1，官方 FSRS-6 / 21参数。持久 card/log/model/参数/retention/evidence。Again 不保旧过期due；自动归属不由用户撤销取消 |
| 真实计划、当日预算 | domain/study_service.dart; presentation/plan_page.dart | 上海日界线；只已到期任务入默认队列，未来列在计划中；每日总量/新学减当天消耗，保守3分钟/任务。版本冲突防覆盖 |
| Agent 冻结对象→贡献保存→安排→撤销 | application/study_tools.dart; data/study_review_storage.dart | stable runtime tool command ID；真实 finalText 授权；事务末 cancellation lease；receipt/outbox 原子提交；撤销仅本贡献，保历史/自动任务 |
| 双模式真实语音/数字人 | study_runtime owner; presentation/coach_page.dart | 全局runtime；普通文字/按住输入、连续语音、同一个数字人全屏/收起、静音/扬声器/挂断；设备与云服务验证见下文 |
| 考试冻结范围与分阶段评分 | data/study_exam_storage.dart; presentation/exam_page.dart | active → submitted → graded → published；未发布不暴露参考答案/成绩，进行中不允许查词/普通练习；当前真实客观中→英拼写题型 |
| 真实统计与技能弱项 | domain/study_analytics.dart; presentation/statistics_page.dart | 实际尝试/独立/提示/忘记，真实FSRS状态计算预测；清楚标模型估计，不伪装观察到的记忆概率或长期掌握 |
| 设置、备份/恢复 | presentation/profile_page.dart; data/study_backup_validation.dart | 正式复制备份、粘贴预览与确认恢复；schema/namespace/枚举/类型/JSON/引用校验后原子替换；非法备份保原库 |
| SOE异步增强 | capability disabled | 无key，不阻断基础学习；发音自练不产生评测分数。真实SOE适配/质量检验等待用户资源，不声称已实现 |

## 边界

本机 API 密钥、DUIX 私有 SDK、数字人/ASR 大型模型不进入 Git。CI 只跑可重复代码、领域/界面和公开词库检查；本机真实模型 APK/模拟机集成须另外记录，不拿静态分析或 APK 生成代替安装运行验收。

目前考试评分为冻结的 exact-match-v1 拼写规则，不冒充开放口语/作文考试或综合英语能力评估。英语/中文语音识别采用 MiniMax 云端 asr-1.0，需要网络；不会把底座现有中文离线模型称为英语识别。Flutter官方pubspec flavor assets（https://docs.flutter.dev/tools/pubspec）用于隔离：foundation保留原ASR权重，study仅打包英语学习轻量资产。英文参考朗读需实际在线音频服务可用；失败/静音显示不可用并可转阅读补练。SOE off 只记录自练完成，ASR 识别文本不是发音分数。

## 当前源码验证

生产源码 `a4a140a403c998efa369423396a3fb0232caa8cc` 的 [PR CI](https://github.com/Namson666/ai-secretary-foundation/actions/runs/37301712675) 与 [push CI](https://github.com/Namson666/ai-secretary-foundation/actions/runs/37301709085) 均成功：ASCII checkout 标准 `flutter analyze` 0问题（10.1秒），完整测试186通过、2个底座已有跳过，公开词库计数检查通过。

测试包含真实SQLite、学习/考试/备份界面、领域取消与幂等、语音owner、工具播放、正式撤销回执、FSRS损坏备份拒绝，以及全屏临时inactive保留通话/未发送录音取消。Avatar与Coach测试确认Hybrid Composition、同一个avatar跨全屏/收起和创建销毁配对。此前本机全仓 `dart analyze` 0问题、网页保留资产26测试通过；diff检查通过。本机 `flutter analyze` 曾遇LSP初始化截断，CI的标准Flutter分析实际通过。源码测试与设备验收分开记录；最终仅文档HEAD须另对应CI。

## 实际模拟器与服务验收

独立 `Shiyu_Acceptance_API34` 使用已有官方API34 ARM64镜像，单实例、保留userdata；没有改动health项目。最终包通过默认launcher启动，无特殊renderer intent。仅study的Skia/传统HC避免已定位的模拟器平台绘制等待，底座公共数字人和SDK保持原实现。

最终source a4a140a / APK 3cb2b87e 的默认release实际复验：

- 黑色首页、四本核心精选、真实选词与保存后重启、中文猜英文遮挡/揭答通过。
- 真实小秘数字人就绪，全屏系统首次“Got it”说明后通话仍保持；收起/再次全屏、静音、扬声器关闭及结束通过。结束后前台语音服务/AppOps录音使用均归零。
- 19:34:20真实MiniMax请求调用收录工具，正式回执 `committed / pending` 表示已保存、时间尚未安排；19:36:10下一轮真实撤销成功，原卡本次贡献标已撤销，其他收录和练习历史保留。本轮无529，回执对应领域实际提交，不按模型回复猜成功。
- 根协调者独立核对数字人全屏与回执像素、云服务错误边界；没有保存测试截图。

此前合并设备入口 `integration_test/study_device_acceptance_test.dart` 的6项实跑5通过、1遇云服务HTTP529：真实DUIX/TTS/生产VAD/云ASR与录音器取消、Coach全屏收起播放，以及三条原生SQLite学习、冻结回执安排撤销、考试草稿评分发布通过；529明确报错且没有假保存。最后release的真实跨轮收录/撤销复验单独记录，不把两次运行拼成“6/6自动集成通过”。

新独立AVD首次资源冷初始化：17:08:32.538开始解压，17:08:35.226复制完成，17:08:38.302实际DUIX初始化成功，约5.8秒；第二Coach热view在17:09:17.570就绪，未据单点推算热启动耗时。这是资源/数字人初始化时间，不是整个应用启动耗时。旧health AVD的62秒慢复制/system_server故障不计入产品正常时间，原userdata保留。180秒deadline只表示冷初始化容错上限。

真实云ASR曾用4.60秒中英参考WAV返回HTTP200：“Hello, I'm learning English today. 今天我想练习英语。” 同一语音owner的TTS、生产VAD和实际录音器取消也经设备验证。参考PCM输入、录音器生命周期、真人讲话端到端是不同证据；实体手机和真人讲话端到端尚未验证。

## 本机构建入口

已有 foundation 文档的 `lib/main_foundation.dart` / foundation flavor 构建方式保持有效；英语产品必须明确使用独立入口和flavor：

```sh
flutter clean
flutter pub get --enforce-lockfile
flutter build apk --release --flavor study -t lib/main_study.dart --target-platform android-arm64
```

该命令需要用户本机已配置的Android/JDK、DUIX私有资源及MiniMax运行配置。Study轻量词库与备用形象仅属于study flavor；中文离线ASR资源只属于foundation flavor。CI分析源码并运行可重复测试，不构建或上传含运行配置的APK；APK只在本地交付。

## 当前工件

生产源码 `a4a140a403c998efa369423396a3fb0232caa8cc`，freshclean release构建195.8秒，373737430字节（约356.4MiB），SHA256 `3cb2b87e7b4e58cc0225dfbf46e5abfdf2c516b8531a290c5daa79cef8e92a7a`。实际AOT确认 `ExpensiveAndroidViewController`、中文技能提示与云ASR；仅ARM64，manifest `EnableImpeller=false`，无integration插件与旧中文ASR权重。应用“拾语”/ `com.namson.shiyu` / `1.0.15+16`，minSdk26 / targetSdk36。

最终只读审计：新boot的19:21至19:39没有am_anr，挂断后前台服务为空、RECORD_AUDIO没有running状态。停止应用后取完整数据库快照（实际无WAL/SHM，journal为0字节），integrity_check为ok；27个已选词，might已选，might发音贡献active=0且复习点cancelled，保存与撤销均有committed回执。原始本地证据为ignored的 `.gradle-build/study-hc-native-audit.txt` 与 `.gradle-build/study-hc-db-audit.json`，不上传私人数据库。

本地交付为 `交付/拾语-1.0.15-arm64.apk`，绝对路径 `/Users/Namson/Documents/Codex/APP开发/english-study-web-preview/交付/拾语-1.0.15-arm64.apk`。同目录含 `SHA256.txt` 与验收说明，仅在private/ignored目录保留（目录700、文件600），不进入Git或CI artifacts。Android签名验证退出码0，目前使用Android Debug签名供本地安装测试，不是商店发布签名。

最终仅保留1个APK文件/1个版本；build重复工件、旧候选、探针class/dex、临时数据库快照与预览server8766已清理。仅本项目AVD实例与其netsimd、Gradle/Kotlin闲置进程已停止，AVD userdata保留；用户4173网页预览与health工作区保留，health git clean。测试截图0。后续仅文档提交不改变上述生产源码树，不需要重新构建同一APK。

## 已撤回候选与兼容修复

以下候选均不交付，也不用其中局部通过结果冒充最终验收：

| 候选SHA256前缀 | 实际问题 | 后续处理 |
|---|---|---|
| 1b6a3f698b00 | 旧AOT仍显示本地ASR，未与生产源码对齐 | 正式清理构建/Dart生成缓存、刷新插件并fresh重编；旧候选已删除 |
| c2cd382cb381 | 默认Impeller启动33.7秒发生ANR；main停在FlutterJNI.nativeSurfaceCreated，raster停在emulator GLES/QemuPipe。软件GPU首页1560ms但AI阶段又发生5189ms输入等待 | 只对study固化Skia；不改用户其它项目 |
| e9b84176c0ff | Skia默认包全屏后TLHC路径阻塞：main为Surface.HwuiContext.unlockAndPost/平台wrapper.draw，DUIX GL线程eglSwapBuffers/QemuPipe等待，raster空闲；降display未解决 | 只对StudyAvatar采用传统HC，review后新source a4a140a / fresh工件3cb2 |

最终验收使用默认launcher与上述正式配置，不交付只能靠特殊启动intent运行的包，也不据模拟器数据推算真机性能。
