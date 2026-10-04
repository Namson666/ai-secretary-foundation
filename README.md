# AI Secretary Foundation / 数字人底座

这是从 AI 健康助理 `1.0.15+16` 提取的**底座源码公开版**，用于在同一 Flutter/Android 架构上开发学习助理等新项目。它不是 DUIX 官方项目，也不是可直接导入任意视频的数字人训练工具。

## 包含什么

- Flutter 数字人首页、基础设置、文字与语音对话、会话/本地记忆、模块工具注册与按需搜索。
- `AppProfile` 应用配置、输入开始时捕获的页面对象引用、本轮固定的工具 schema 与路由；可用于让领域 Agent 理解“把这个加入复习”中的“这个”。
- Android `PlatformView`/`MethodChannel` 对接代码和通话前台服务。
- 底座接口及架构文档：[底座说明](docs/FOUNDATION_OVERVIEW.zh-CN.md) · [接口说明书](docs/FOUNDATION_INTERFACES.zh-CN.md) · [本次优化范围与验证](docs/FOUNDATION_OPTIMIZATION_STATUS.zh-CN.md)。
- 不包含健康版的训练界面、训练工具、动作目录或健身媒体。源项目的通用数据库/记忆实现仍留有兼容旧版的训练字段与查询；这部分尚待进一步模块化。

## 不包含什么，为什么

本仓库**有意不上传**以下内容：

| 文件/资源 | 处理方式 |
| --- | --- |
| `android/local.properties`、`android/key.properties`、签名 `*.jks` | 私人 API 凭据和签名材料，永不提交。 |
| `android/duix-sdk/`、`android/app/src/main/assets/duix/` | DUIX SDK、基础包和数字人模型资源；需由使用者按原始许可自行取得。 |
| `assets/asr/zipformer/model.int8.onnx`、`tokens.txt` | 本地 ASR 权重及词表；分发许可未在此仓库确认。 |
| APK/AAB、构建缓存、测试截图、健康版源码 | 不属于底座源码公开范围。 |

**所以当前仓库不能仅凭 `git clone` 生成完整可运行的数字人 APK。** Dart/Android 对接源码可阅读和修改；编译及数字人运行需要补齐上述被排除的合法依赖。不要把这份源码导出误认成可运行的演示包或完整 SDK。

## 本地接入

1. 使用与 `pubspec.yaml`/Android Gradle 配置兼容的 Flutter、Dart、Android SDK，运行 `flutter pub get`。
2. 按 [DUIX 官方项目](https://github.com/duixcom/Duix-Mobile)及其许可取得 SDK，放入 `android/duix-sdk/`；此目录需要是可被 Gradle 识别的 `:duix-sdk` 模块。按 SDK 要求放置运行资源到 `android/app/src/main/assets/duix/`。当前原生资源加载器期待 `gj_dh_res.zip` 与 `小秘/` 模型目录；具体资源必须有合法使用权。
3. 为本地 ASR 取得与代码配置匹配的模型文件，放入 `assets/asr/zipformer/`。当前实现按文件名和大小校验 `model.int8.onnx` 与 `tokens.txt`；使用其他模型需同步修改 [`LocalStreamingAsrService`](lib/services/local_streaming_asr_service.dart) 的配置。
4. 让 Flutter 工具生成 `android/local.properties`，按需填入自己的服务凭据。可参考 [`android/local.properties.example`](android/local.properties.example) 的**字段名**，不要提交真实值。未配置服务时，对应云能力无法使用。
5. 补齐依赖后构建：

```bash
flutter build apk --release --flavor foundation -t lib/main_foundation.dart --dart-define=FOUNDATION_APP=true
```

没有 `android/key.properties` 时，当前 Gradle 配置可能以调试签名生成 release APK；它不应作为公开发行包。Android 最低版本为 API 26。真实语音、锁屏通话、DUIX 播放/口型以及百炼搜索需在自己的设备与账户上验收。

## 新模块怎么加

实现 [`AssistantModule`](lib/core/assistant/assistant_module.dart)，将专属工具与业务仓储放在 `lib/features/<domain>/`，在新应用入口覆盖 `assistantAppProfileProvider` 和 `assistantModuleRegistryProvider`，并提供路由、数据迁移和测试。页面通过 `assistantContextProvider` 提供稳定对象 ID；底座在文字输入、单次录音开始或连续通话的 `onSpeechStart` 捕获应用、注册表与页面上下文。后续提示、工具列表和调用使用同一份 `AssistantModuleSelection`，页面切换不会把已开始的输入改指向新对象。参考[接口说明书](docs/FOUNDATION_INTERFACES.zh-CN.md)中的装配和调用示例。

`AppProfile.dataNamespace` 当前只校验上下文归属，**没有按命名空间迁移或隔离 SQLite 数据**。现有 `ai_secretary.db`、schema 6、旧表及健康模块的确认钩子保留。明确、可逆的“加入复习”可由学习模块直接执行并返回真实结果；是否需要确认由领域工具决定，底座不强制所有写操作再次确认。

通用层目前只内置 WebSearch。学习计划、单词、考试、发音评测和数字人控制的领域工具仍需开发。未来腾讯 SOE 应作为可选异步旁路：未启用、超时或不可用时继续现有 ASR → LLM/工具 → TTS → 数字人流程；本次没有接入 SOE，也没有改变原生播放错误的传播方式。

## 源码验证

安装与 `pubspec.yaml` 兼容的 Flutter/Dart 并完成依赖解析后，可运行：

```bash
flutter pub get
flutter analyze --no-pub
flutter test --dart-define=FOUNDATION_APP=true --no-pub
```

测试覆盖模块兼容、输入上下文、异步取消、记忆/RAG 一致性和音频实例归属，使用受控服务替身与本地 SQLite。具体工具链、最终结果和未覆盖范围见[优化状态](docs/FOUNDATION_OPTIMIZATION_STATUS.zh-CN.md)。这些测试不代替 APK 构建、付费云接口或真机验收。

## 安全与授权

代码中的 API key 通道最终读取 `BuildConfig`；把密钥编进 APK **不能保密**。公开发行应使用后端代理或短期凭据。DUIX 有独立社区许可及署名要求，详见[第三方说明](THIRD_PARTY.md)。本仓库**未添加项目许可证**；公开可读不等于授予复制、修改或再分发本项目代码的许可。

这是一份源码范围清晰的公开副本，不会与私有健康助手仓库自动同步。本 README 及接口文档以 2026-10-05 的代码审查为准；云服务、设备兼容和第三方授权状态仍须使用者独立核验。
