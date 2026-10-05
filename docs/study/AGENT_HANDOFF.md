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

当前生产源码提交 `a4a140a403c998efa369423396a3fb0232caa8cc`。该版本的 [PR CI](https://github.com/Namson666/ai-secretary-foundation/actions/runs/37301712675) 与 [push CI](https://github.com/Namson666/ai-secretary-foundation/actions/runs/37301709085) 已成功：标准 `flutter analyze` 0问题，完整测试186通过、2个底座已有跳过。网页保留资产26测试通过，diff检查通过。早期合并模拟机集成6项实跑5通过、1遇云服务529；最终默认release又单独完成真实跨轮收录/撤销、学习保存重启与数字人全屏/收起/结束，不把两次结果拼成6/6自动集成通过。

Study flavor 单独设置Skia渲染，foundation不改。系统全屏说明弹窗的临时inactive保留通话；未发送的按住录音取消，真正paused/hidden/detached仍释放通话资源。两条新增回归已包含在186项中。最终默认launcher安装包实际全屏首次“Got it”后保持通话，收起/再全屏/静音/音频关闭/结束通过；结束后前台服务与录音AppOps归零，不依靠特殊启动intent。

旧候选默认包曾出现Impeller与TLHC绘制等待，仅study的 `StudyAvatar` 改传统Hybrid Composition；底座公共数字人/SDK不改。平台创建后的180秒冷初始化边界、旧channel隔离、retry、同一个avatar跨全屏/收起、1次创建对应1次销毁都有测试；上述a4a140a CI覆盖最新合成路径。旧候选全部撤回，不引用旧候选局部成功冒充最终包验收。

## 安装与使用交代

面向ARM64 Android 8.0及以上设备（minSdk26），应用名“拾语”，独立包名 `com.namson.shiyu`，版本 `1.0.15+16`。APK SHA256为 `3cb2b87e7b4e58cc0225dfbf46e5abfdf2c516b8531a290c5daa79cef8e92a7a`，373737430字节；源码a4a140a的freshclean默认release。交付文件为 `/Users/Namson/Documents/Codex/APP开发/english-study-web-preview/交付/拾语-1.0.15-arm64.apk`，同目录有SHA256与验收说明，private/ignored不上传Git。Android签名验证通过，目前是Android Debug签名供本地安装测试，不是商店发布签名。

19:21至19:39无am_anr，挂断后无前台服务/录音running。停应用后完整SQLite快照integrity为ok，无WAL/SHM，保存/撤销正式committed且本贡献inactive；私人审计仅本地ignored保存。最后保留1APK/1版本、0测试截图，旧候选/build副本/临时探针和数据库快照已清理；仅停止本项目AVD/闲置构建进程，userdata保留。4173网页预览保留，health git clean。最后的文档提交不改变APK生产源码树。

内置4本开源词典核心精选，日常1000、高中1500、四级1500、六级1500；不是整套考试词库完整覆盖。学习记录与备份真实存于本机独立数据库。AI、MiniMax云ASR与参考朗读需要网络及用户本机运行配置；SOE关闭时仍可学习和发音自练，不提供自动发音分数。最终包19:34:20真实ADD正式committed/pending回执、19:36:10下一轮UNDO正式撤销本贡献通过，其他历史保留。本轮无529。模拟器合成PCM输入、真实麦克风生命周期已有独立证据，尚未验证真人讲话端到端或实体手机。

开发分支为 `codex/english-android-app`，草稿 [PR #3](https://github.com/Namson666/ai-secretary-foundation/pull/3) 叠加网页分支；底座PR #1、网页PR #2和原生PR #3均未在本阶段合并。正式源码与后续仅文档提交需分别记录，最终PR HEAD CI也必须成功。

下一接手先核对 git status、最终提交与设备验证记录。保留本地新改动，不重建已有私有资源，不删除其他项目成果。禁止保留测试截图，构建版本最多两版。
