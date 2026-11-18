# FusionPlay for iPhone and iPad

这是 FusionPlay 妙播接收端的 iOS / iPadOS 测试版。使用原生 SwiftUI，复用 Mac 版的 Rust 接收核心、UniFFI 接口以及封面、歌词、进度和系统媒体的共用逻辑。最低运行版本为 iOS 17 / iPadOS 17。

首次打开后点「开始接收」并允许访问本地网络。在同一局域网的发送端打开小米妙播，选择 `FusionPlay-iPhone` 或 `FusionPlay-iPad`。设备名可在设置里修改。开启歌词后，iPhone 和窄窗口在播放器下方显示歌词，宽屏 iPad 并排显示。播放、暂停、切歌和跳转经发送端确认，歌词与封面由发送端提供。

这个版本在前台接收。进入后台或锁屏时释放接收器，回到前台后按之前的接收状态重新启动。原会话可能需要在发送端重新选择。来电等系统音频中断结束后，按系统给出的恢复意图处理。

## 构建

需要 Apple Silicon、Xcode 16 或更新版、Rust stable，以及两个 iOS Rust target。

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
bash ios/scripts/build.sh device
bash ios/scripts/build.sh simulator
```

脚本分别生成 ARM64 真机和模拟器用的未签名 `FusionPlay.app`，输出为项目外层的 `artifacts/ios-device/` 和 `artifacts/ios-simulator/`。可用 `FUSIONPLAY_IOS_PROJECT_ROOT` 指定项目产物根目录。构建缓存和绑定都在该目录，`ios/.generated` 是指向生成内容的本地符号链接。

在 Xcode 运行时，先执行 `bash ios/scripts/prepare.sh all`，再打开 `ios/FusionPlay.xcodeproj`。真机安装需要在 Signing & Capabilities 选择具有合适描述文件的团队。模拟器运行需要已安装 iOS 模拟器运行时。

## 验证范围

- 局域网发现使用系统 Bonjour 注册 `_lyra-mdns._udp` 和 `_mi-connect._udp`。小米手机对系统 Bonjour 广播的兼容情况须在真机上验证。 [Apple 本地网络权限说明](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- 真机首轮验证顺序：允许本地网络权限 → 小米手机发现 → 连接并出声 → 暂停、切歌和跳转 → 封面与歌词 → 退到后台再前台重连。分别核对 iPhone 的窄屏和 iPad 的宽屏、多任务布局。
- 当前版本以 Wi-Fi 或有线局域网 IPv4 为目标。全屋同步、锁屏持续接收和各音频输出路由的行为尚未验收。
