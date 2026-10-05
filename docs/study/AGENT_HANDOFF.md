# 拾语原生阶段交接

当前工作分支 `codex/english-android-app` 承接网页确认分支 `codex/study-web-preview` 的 `2354d185fbc042ba18eebee56ed31a7df2d469f3`。原底座优化 PR #1 和网页 PR #2 不在本阶段擅自合并。实际入口是 `lib/main_study.dart`，study flavor 的独立应用标识 `com.namson.shiyu`；保留 `lib/main.dart` 与 foundation flavor。

## 实际代码与接口

- 学习 UI → Riverpod 应用服务 → 纯 Dart 领域接口 → 独立 `study.sqlite`。同词不同技能使用独立 FSRS 卡；学习记录、计划、命令回执与撤销贡献真实保存。不要将 profile 的 namespace 当数据库隔离。
- `StudyTools` 使用真实用户原话做操作授权，输入开始时冻结 focus；命令稳定标识与取消 lease 由 runtime 提供，领域事务提交前再检查。已提交事实不受后续显示刷新失败覆盖。
- 只有回执 `status=committed` 表示提交成功，`schedule_status=pending` 表示尚未安排；撤销按钮只接受 `undoable=true`，不按 point_id 的形状猜。撤销仅本次贡献，保自动排程与其他历史。
- 词库为固定 ECDICT MIT 来源的4本核心精选（1000/1500/1500/1500），跨词书共享状态。源词并集2468，另外6个独立卡共2474词；界面自写例句独立标注来源，缺失例句不补假权威内容。
- FSRS-6 通过精确锁定 `fsrs:2.0.1` 的 adapter；卡、参数、desiredRetention、版本、evidence cursor 持久化。恢复备份先完整验证字段、步骤状态与引用，再事务替换。
- 考试为真实客观中→英拼写规则，冻结范围与题目；提交、评分、发布分开，发布前不暴露参考答案。不是综合英语能力或自动口语评测。

## 运行资源与验证边界

真实语音采用 MiniMax 云 ASR（asr-1.0）、LLM（MiniMax-M3.1-Flash-Preview）与 TTS，需要网络和用户本机密钥。它们已由 native owner 做实际服务核验，不能据 API 成功推断真人麦克风端到端验收。设备集成里的参考 PCM 输入、实际录音器生命周期与真人讲话须分别记录。DUIX 用用户已有私有 SDK/模型；失败时明确显示数字人不可用，备用预览形象不冒充数字人就绪。

SOE 默认关闭，没有评分密钥时基础流程持续可用，发音自练只记录练习证据，不把 ASR 文本或自评当自动发音分数。Study 不打包底座中文 ASR 权重，foundation 原能力仍保留。密钥、local.properties、SDK、模型和 APK 均不进入 Git。

本阶段最新源码验证：native owner 在 Avatar 冷启动修复后 Flutter 全量184通过、2个已有跳过、0失败；此前全仓 Dart 分析0问题，修复3文件另分析0问题；网页测试26通过；diff检查通过。模拟机集成、最终 release APK 内容/签名/安装及 exact HEAD CI 需按实际结果追加，不能用“APK编译成功”替代安装与流程验收。

下一接手先核对 git status、最终提交与设备验证记录。保留本地新改动，不重建已有私有资源，不删除其他项目成果。禁止保留测试截图，构建版本最多两版。
