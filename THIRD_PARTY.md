# 第三方组件与资源

本公开仓库保留了调用 DUIX 数字人 SDK 的适配代码，但**不包含** DUIX SDK、数字人模型、运行资源、ASR 模型权重、API 凭据或 APK。

- DUIX 官方项目：[duixcom/Duix-Mobile](https://github.com/duixcom/Duix-Mobile)。使用或分发其材料前，请阅读官方随附许可。原工程随附的 DUIX Community License 要求保留许可与 Notice，并在相关界面、网站或文档显著展示 “Powered by Duix.com”；本仓库不代替使用者取得授权。
- Flutter/Dart 依赖由 `pubspec.yaml` 声明，Android 依赖由 Gradle 文件声明。各依赖的许可证独立适用。
- 本地 sherpa-onnx ASR 权重来源与再分发权未在本仓库确认，因此不上传模型文件。`sherpa_onnx` 软件包自身的许可与模型权重许可应分别核对。
- DeepSeek、MiniMax、百炼等为可配置的云服务接入点；本仓库不提供其 API 凭据或服务额度。

本项目代码没有附加通用许可证；不要把第三方许可理解为本项目代码的授权条款。
