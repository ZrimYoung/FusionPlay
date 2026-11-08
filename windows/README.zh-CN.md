# FusionPlay Windows · 测试版

Windows 10 22H2 / Windows 11 x64 原生 MiPlay 音乐接收器。界面使用 C# / WinUI 3，协议与音频使用共享 Rust 核心。首版只接收小米妙播。

## 使用

1. 将完整 ZIP 解压到可写目录，双击 FusionPlay.Windows.exe。不要只复制 EXE。
2. 打开后自动开始接收。手机、电脑、音箱连接同一局域网，在手机妙播中选择 FusionPlay-Windows。
3. 全屋播放在手机中添加音箱和此电脑。关闭播放窗口后仍在托盘运行；托盘“退出”才停止整个应用。

托盘左键打开接收面板，右键提供显示窗口、设置、接收启停与退出。播放窗口与托盘共享音量和控制状态。

播放、暂停和切歌发给手机，界面区分“已发送”和“手机已确认”，不会因未确认而重复切歌。手机没有提供时长/位置时不显示虚构进度；首版不支持进度跳转。

实际播放后接入 Windows 系统媒体卡片和媒体键。停止、断开和退出时清理本应用媒体信息；多个音乐应用同时运行时，媒体键目标由 Windows 决定。

## 连接与声音

自动选择优先采用有网关的物理 Wi-Fi / Ethernet。必要时在设置中手动选择网卡，保存后在手机上重新选择设备。应用不会修改代理或 VPN 设置。

声音输出默认跟随系统，也可固定设备。若电脑默认输出为没有扬声器的显示器，请在应用中选择实际扬声器。固定设备断开时提示错误，不静默切换到其他设备。

网络及默认输出改变时受控重连，失败最多重试三次。睡眠停止接收，唤醒后只恢复用户此前请求的接收状态。

如果 Windows 提示访问网络，请允许专用网络。设置中的“允许局域网连接”可为当前程序路径添加仅限专用网络、本地子网的入站规则；这一步请求管理员权限，应用本身不需要管理员权限。移动程序后可能需要重新配置路径规则。

不安装登录启动项；运行所需组件随包提供。

## 便携数据与升级

程序旁的 FusionPlayData 保存设置、设备身份与轮换日志。升级时退出应用，替换程序文件并保留这个目录。

同一电脑内移动整个目录保留身份。复制到其他电脑/用户时，本机保护的归属标记可能无法读取；应用要求明确选择“为此电脑建立独立身份”，保留通用设置并备份旧身份，不重置手机数据。

目录不可写时显示错误，不暗中切换数据目录或生成另一身份。封面只在内存加载，支持 HTTP/HTTPS、Data URL 和无前缀 Base64，最大 4 MB。日志不记录认证材料、原始网络包、曲目或封面内容。

## 构建

需要 PowerShell 7、Visual Studio C++ Build Tools（MSVC x64）和 Windows SDK。准备脚本将 .NET 10.0.403、Rust MSVC 和缓存放在项目专用目录，不修改系统 PATH；可用 FUSIONPLAY_WINDOWS_TOOLS 指定工具目录。

~~~powershell
./windows/scripts/setup-tools.ps1
./windows/scripts/build.ps1
./windows/scripts/test.ps1
# 应用关闭后额外执行本机真实网络启停检查
./windows/scripts/test.ps1 -Network
./windows/scripts/package.ps1
~~~

真实默认音频端点的静音渲染检查：

~~~powershell
. ./windows/scripts/env.ps1
cargo test --locked --manifest-path ./src/FusionPlay.MiPlaySdk/Cargo.toml --lib silent_native_endpoint_renders_and_pauses -- --ignored
~~~

Windows 原生工程位于 windows/FusionPlay.Windows，便携数据与 C ABI 封装位于 windows/FusionPlay.Core，集成测试位于 windows/FusionPlay.Tests。Mac UniFFI 和 Android JNI 保持各自现有接口。

## 验收边界

测试版。自动化测试、静音端点渲染及内部调度误差不能替代手机实播和声学同步验收。

全屋同步目标为 20 ms，需要同次录音中的瞬态信号，控制麦克风距离差，覆盖至少 30 分钟的初期、中段和末段。蓝牙不纳入首版同步验收；没有实测数据时不标记达标。详见源码中的 windows/VALIDATION.md。

设置中的“声音同步校准”与 Android 端用法一致：电脑比同组音箱慢时按 +10，每次提前 10 毫秒；调过头时按 −10，也可输入具体数值或“归零”。范围 0–500 ms，默认 0。调整时短暂淡出再恢复，立即生效并自动按声音端点保存，不需要重新连接。更换输出后会读取该设备的独立设置。可先按听感调整；是否达到 20 ms 目标仍需声学测量确认。

项目继承 AGPL-3.0-only。包内附许可证、第三方说明和 build-info.json 中的对应源码提交指针。
