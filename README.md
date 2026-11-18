# FusionPlay

FusionPlay 是一个面向全平台的局域网音乐投放接收器，支持 MiPlay AirPlay DLNA

本分支的 Android 客户端使用 Kotlin 和 Android 原生控件，最低支持 Android 7.0（API 24），适配手机、平板和 Android TV。接收、协议和音频继续复用现有 Kotlin 服务及 Rust 核心。

项目同时维护 SwiftUI + Rust 原生 macOS MiPlay 接收器。Mac 当前为测试版，使用说明、构建及实播验收状态见 [macos/README.md](macos/README.md)。

仓库也包含 C# / WinUI 3 与共享 Rust 核心实现的 Windows 原生 MiPlay 接收器，提供便携测试包和手动声音同步校准。构建和使用见 [windows/README.zh-CN.md](windows/README.zh-CN.md)，实际验证范围见 [windows/VALIDATION.md](windows/VALIDATION.md)。

## 目录结构

```text
flutter/android/        原生 Android Gradle 工程、Kotlin 界面与后端、单元测试
flutter/lib/            旧版 Flutter 界面，保留作迁移对照
macos/                  macOS 原生应用、构建脚本与测试
windows/                Windows 原生应用、便携打包与测试
src/
  FusionPlay.Host/       macOS UniFFI / Windows C ABI 与共享接收器生命周期
  AirPlayReceiver.Core/ AirPlay、DLNA、音频和 JNI 核心
  FusionPlay.MiPlaySdk/ 小米妙播协议与媒体接收
  FusionPlay.AndroidIfAddrs/ Android 5 网络接口适配
vendor/shairplay/       带本地修复的上游 AirPlay 实现
tools/                  图标、抓包和诊断辅助工具
```

项目只有 `flutter/android/app` 一个 Android 应用模块；Rust 动态库由该模块的 `buildRustNative` 任务生成到 Gradle 构建目录，不会写入源码树。

## 原生 Android 播放器

界面以 [FusionPlay iPadOS 参考分支 c6520c1](https://github.com/ZrimYoung/FusionPlay/tree/c6520c10c8d23badc88c0a8ba710bada2a74eab5/ios) 为依据。宽屏在无歌词时左右摆放封面和控制，打开歌词后左侧是封面和曲目信息、右侧是歌词。窄窗和大字体模式将同一内容纵向排列。播放页可点按唤出歌词、音量和设置，电视用遥控器进入相同控件。歌词依现有接收数据和曲目位置跟随，手动浏览一段时间后自动恢复。

设置在播放器上打开，接收服务继续运行。保留设备名称、各协议独立开关、妙播设备类型、同步校准、自动唤醒、播放亮屏和日志导出。进度、播放按钮、歌词、工具栏和曲目信息换行的显示偏好在本机保存。

## 构建环境

- Windows 10/11 与 PowerShell 7。
- Android SDK 36、Android NDK 28.2.13676358。
- JDK 17 或 21，Gradle 由工程 Wrapper 提供。
- Rust 工具链以 `src/AirPlayReceiver.Core/rust-toolchain.toml` 为准。Windows 已安装 MSVC Build Tools 时，也可用 `RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-msvc` 配合 NDK。给所用工具链安装 `armv7-linux-androideabi`、`aarch64-linux-android`、`x86_64-linux-android` 目标。
- `cargo-ndk` 可执行文件位于 `CARGO_HOME/bin` 或 `PATH`。

标准环境变量为 `ANDROID_HOME`（或 `ANDROID_SDK_ROOT`）、`JAVA_HOME` 与 `CARGO_HOME`。使用集中工具目录时也可设置 `FUSIONPLAY_TOOLS_ROOT`。本分支的 Android 构建无需 Flutter SDK。

## 检查与测试

使用 Gradle Wrapper 执行 Kotlin 单元测试：

```powershell
.\flutter\android\gradlew.bat `
  -p .\flutter\android `
  :app:testDebugUnitTest `
  --no-daemon
```

Rust 模块可分别运行 `cargo test` 和 `cargo clippy`。Android 原生库需要通过完整 APK 构建验证对应 NDK 目标。

## 构建通用 APK

```powershell
.\flutter\tool\build_universal.ps1
```

脚本通过 Gradle 构建包含 32 位 ARM、64 位 ARM 与 x86_64 的单一 APK，并将 APK 保存到 `artifacts/android-native/`。需要与旧版并存时，可用独立测试包名构建：

```powershell
.\flutter\tool\build_universal.ps1 -Configuration Debug -ApplicationId com.fusionplay.android.nativepreview
```

当前 Release 配置在没有私有签名配置时使用 Android 调试签名，公开发布商店版本前应替换为自己的安全签名流程，且不得提交密钥文件。

## 小米电视端口冲突修复

部分小米电视的系统接收器已经监听 TCP 8899。FusionPlay 现在优先使用该端口；仅当端口被占用时，由系统分配空闲端口，并在 Lyra 的 PeerPort 握手响应及 Mi Connect 的 appsData 发现记录中返回实际监听端口。原有系统接收器无需停用。Android 会保存成功使用的控制端口，并在下次启动时优先复用。HyperOS 可能按 MAC 缓存旧端口和能力；若此前误连了盒子系统的 8899 接口，即使更新发现记录，手机仍可能保留仅视频能力。调试时需备份后更新 FusionPlay 的独立身份以重新获取能力，无需清除手机数据。

`fix/miplay-port-conflict` 分支提供 GitHub Actions 自动构建，也可在 Actions 中手动运行 **Build Android port fix**。成功后可下载 `FusionPlay-1.2.4-portfix-debug` APK 构建产物，保留 30 天。测试版包名为 `com.fusionplay.android.portfix`，可与原版同时安装；验证时请关闭原版 FusionPlay，避免 AirPlay 和 DLNA 端口冲突。

默认构建仍包含全部三种 ABI。定向调试时可通过 Gradle 属性 `fusionPlayAbis` 指定逗号分隔的 ABI，并通过 `fusionPlayApplicationId` 指定独立测试包名。

## 协议与商标说明

本项目仅为网络互操作实现，不包含或调用小米、Apple 或其他厂商的私有运行库、账号服务或设备证书。AirPlay、Apple、小米、妙播、DLNA 等名称及商标归各自权利人所有，本项目与这些厂商没有隶属或官方认证关系。

## 许可证

FusionPlay 原创源码使用 [GNU Affero General Public License v3.0](LICENSE)，SPDX 标识为 `AGPL-3.0-only`。项目内第三方组件继续适用各自许可证，详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 与对应依赖源码或元数据。
