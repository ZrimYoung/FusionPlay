# Mac 首版验证记录

## 0.2.5 菜单栏尺寸与重复设备诊断

- 菜单栏双环从 24×18 pt 缩为 20×16 pt，线宽从 1.8 缩为 1.5；Dock 图标和菜单面板布局保持原样。图标回归、原生构建、严格签名检查通过。
- 修补 Mac 宿主遗漏的网卡地址：使用当前选中网卡的真实六字节单播地址填入 SDK 已有 hardware_address 参数；八位 media ID 不再被当作网卡地址使用。原有 IDM/Lyra/媒体身份文件不变，共享 SDK 和 Android 接口未修改。复用已有间接依赖 getifs 0.6.1，锁文件未升级其他依赖。
- 宿主 8 项测试通过，另 1 项已有网络测试本轮未运行；实际广播读回确认 Mi Connect 的 mac 字段与选中网卡一致，只有一个 Mac Mi Connect 服务实例。
- **重复条目尚未解决，不能将本版标记为串台修复版。** 用户实播仍看到两个同名条目；正确条目在 Mac 播放，错误条目在小米原生接收设备播放，手机一直显示连接中，曲目信息未同步。
- 对照：Mac 退出并撤回广播后，错误条目仍在；手机 Wi-Fi 重连后条目暂时消失，重新扫描又恢复。只刷新发现列表不足以解决。
- 经用户授权连接手机无线 ADB，只读采集妙播日志：CacheDeviceHelper 同时回报同名但不同 IP/MAC 的旧记录与当前记录。旧 IP 现在属于原生接收设备，控制应答也报告其 audio,video 能力；当前 Mac IP 的应答为 audio、deviceId 与 IDM 一致。另一台小米电脑接收软件也存在旧缓存条目，故不能归结为 FusionPlay 启动了两个实例。
- 手机组件版本与本地分析 APK 的 versionCode 一致。该版本将设备缓存存入 miplay_database；普通 ADB 的 run-as 被系统以应用非 debuggable 拒绝，无法精准删除单条记录。未清除任何手机应用数据，未修改电视或 Windows 软件。用户明确选择保留手机设置、不重置互联服务数据；因此旧缓存未清除，串台问题仍未验收通过。
- 原始手机日志及局域网诊断仅保留在独立项目 tmp 目录，不进入源码仓库或交付压缩包。

## 0.2.4 控制连接隔离与音量交互（2026-10-26）

- 修复前复现：单条控制连接错误把等待/播放状态改为 Failed 并清空曲目信息；真实 ReceiverModel 在拖动到 83 后被后台音量 50 覆盖。
- Mac 宿主将控制会话/控制写入错误视为连接局部错误，保留监听和媒体状态；音频输出、监听器与未知错误仍触发接收器故障处理，实际媒体结束仍清空播放状态。共享 SDK 与 Android 接口未修改。
- 日志增加固定枚举的错误范围、恢复策略和粗分类提示，不保存原始错误消息、包内容、地址或凭证。历史错误无法倒推出具体原因。
- 音量使用独立的交互状态：拖动和提交期间保护草稿，等待命令完成与音量回报；处理旧回调、连续拖动、提交失败与回报超时，并保留提交后的重连音量。
- 宿主状态回归通过；真实本机连接测试发送无效控制头后，接收器保持 Ready 和同一代监听，后续连接仍收到协议响应。诊断记录确认 keep_listening 且无原始错误消息。
- 音量交互状态回归与修复后的真实 ReceiverModel 注入验证通过；原生应用构建及严格签名检查通过。随后用户实播确认“音量正常，没有回跳”。自然断连恢复及长时间全屋同步仍待验证。

## 0.2.3 Dock 图标与精简菜单（2026-10-26）

- 菜单栏与面板统一为单色双环标志；移除重复状态说明、测试版标签、音量百分比和独立接收按钮，底部五个图标提供接收启停、播放窗口、设置、日志与退出，保留悬停说明及无障碍标签。
- Dock 排查确认资源与系统读取结果含双环，实际截图仍为占位图；因此显式设置运行时图标，并仅刷新本应用的系统注册。直接设置原图曾造成白色方块，经用户截图确认后修正为带透明外边距的圆角图块。用户最终确认“正常了”。未重启 Dock 或清除全局缓存。
- 原生构建、严格签名、图标边距/内部不透明/菜单模板回归通过。真实 SwiftUI 菜单渲染检查覆盖深浅色、等待状态、播放状态与长歌名。未修改音频核心。

## 0.2.2 精简播放界面（2026-10-26）

- 保留左右布局，背景改为当前封面模糊与暗色遮罩，移除底部提示/接收启停栏、重复品牌和播放标签、专辑名与音量百分比。菜单栏继续提供接收启停。
- 播放主按钮使用原生 Liquid Glass，macOS 14/15 和旧版编译器回退半透明材质；开启减少透明度时使用实色。
- 使用真实 SwiftUI 视图和示例封面渲染，检查有封面/无封面、长歌名、浅色/深色系统外观；SwiftUI ImageRenderer 确认模糊与玻璃效果。示例图不是手机实播截图。
- 原生构建及严格签名检查通过，应用已重新打开。此次只修改界面与版本说明，音频核心没有改动。

## 0.2.1 封面兼容（2026-10-25）

- 复现旧加载器丢弃有效 `data:image/png;base64,...` 图片；源码同时确认原界面仅接受 HTTPS。
- 新加载器通过内嵌 PNG、无前缀 Base64、JSON 字符串包装、HTTP/HTTPS、缺失来源、非法图片、超限图片、HTTP 503 分类及不接受文件/带凭证 URL 的验证。
- 本机临时 HTTP 图片服务实测通过，测试宿主使用应用相同的 ATS 配置。
- 封面失败增加有限重试、状态提示与手动重载；日志仅记录格式和结果代码，不保存图片或 URL。
- 第一轮手机实播仍没有封面；日志确认来源非空，但被判为 unsupported_source，尚不能确定真实格式。
- 第二轮增加无前缀图片编码兼容，以及手机 content/file/resource 地址分类；原生应用构建和签名检查通过。
- 用户实播确认“封面出现了”；同次日志记录 source_kind=raw_base64、result=loaded。此次实际原因是手机发送无前缀 Base64 图片，旧实现只将其当作 URL。该次手机投送封面通过，不代表所有音乐来源已覆盖。

## 0.2.1 图标、程序坞与自动接收（2026-10-25）

- 采用用户选择的浅底蓝色双环，并按用户要求增加轻微玻璃质感；保存原始 PNG 和生成提示词，多分辨率 ICNS 在构建时生成。
- 应用使用普通程序坞模式；首次打开显示播放窗口，菜单栏入口保留。关闭最后一个窗口继续接收，程序坞重新打开通过 SwiftUI 的窗口入口恢复播放窗口。

- 按用户最新要求，应用完成设置恢复后自动启动接收服务；仅应用进程启动时执行，不会因窗口重开覆盖手动停止状态。没有添加登录启动项。
- 构建、签名、多尺寸 ICNS、封面测试和 Swift/Rust 绑定测试通过。运行时确认程序坞激活策略为 regular、系统读到应用图标，760 宽播放窗口可见；应用启动后无需操作即可记录 receiver_ready。
- 当前环境没有辅助功能访问权限，关闭窗口后点击程序坞恢复窗口的鼠标操作未自动化验证；已实现窗口重开入口。

## 0.2.0 系统媒体与播放窗口（2026-10-24）

- 新增独立“正在播放”窗口、菜单栏播放控制、MediaPlayer 系统曲目与媒体键接入；共享协议和 Android 代码未修改。
- Rust 宿主测试 4 项通过，新增曲目信息增量合并/切歌清理、暂停与恢复状态回归；未连接时四种控制指令均拒绝。
- Swift 绑定验证通过：断连控制拒绝、系统媒体字段映射、缺失时长/进度省略、诊断更新不重置媒体时间、媒体键重复事件抑制、订阅释放和设置持久化。
- 本机原生 MediaPlayer 发布、暂停、停用及信息清理检查通过；接收器连续真实启停 3 次通过。
- 应用仍为测试版：未通过手机实播核对系统卡片显示、实体媒体键、手机实际切歌/暂停、封面下载及全屋联动。上述原生接口检查不等于端到端验收。
- 本版进度只展示，不支持拖动定位；封面仅加载 HTTPS 地址，失败显示占位图。

以下保留首版的历史测试记录。

日期：2026-10-23。状态：**测试版，手机实播未验收**。

## 已验证

| 项目 | 结果 |
| --- | --- |
| 指定基线 | `cab808224244ddf7dc3f53a260225e362e05ce2e`；独立克隆，无 Android 未提交改动 |
| 原始 SDK 单元测试 | 99 项通过 |
| Mac SDK 单元测试 | 105 项通过，包含音频 SPSC 缓冲及 Lyra 重启回归 |
| 宿主测试 | 2 项通过：握手与播放状态区分、身份持久化及目录互斥 |
| Swift → UniFFI → Rust | 连续真实启动/停止 3 次、订阅释放和设置持久化通过 |
| Android 兼容 | `aarch64-linux-android` 和 `armv7-linux-androideabi` SDK 编译检查通过 |
| 清理范围 | 临时目录测试 2 项通过，正式目录只执行清单预览 |
| Mac 应用 | 原生 `.app` 构建成功；启动与正常退出通过；ad-hoc 签名严格校验通过 |
| 部署目标 | 应用及 Rust 动态库的最低系统版本均为 macOS 14.0；仅本机实际运行验证 |

本次修复了两个实际启动问题：Darwin 与 Bonjour 共享 5353 需要 `SO_REUSEPORT`；Lyra 退出需要等待工作线程释放 UDP 端口，才能可靠快速重启。

音频测试使用合成 PCM，覆盖有界溢出、时间戳跳变不跨界插值、欠载淡出、48 kHz → 44.1 kHz 消耗量，以及并发发布不读取不完整音频帧。它们不替代手机传来的真实音频与声学测量。

## 待实播验证

用户本轮选择先交付测试版，因此下列项目没有宣称通过：

- 手机发现、投送、播放/暂停、全屋加入与退出。
- 30 分钟连续播放的毛刺、断音和漂移。
- 与参考音箱的声学偏差是否达到 20 ms 目标。
- 活跃投送时的网络切换、输出设备切换、睡眠唤醒及资源回收。
- Android 实机回归；当前只有原生 SDK 编译检查，未重建或部署 Android APK。

菜单栏内的调度误差不是声学同步测量。实播前建议使用内置扬声器、确认同一局域网并关闭影响本地通信的手机代理。

## 复核位置

本地日志均在独立项目 `logs`：`baseline-test.log`、`mac-core-test.log`、`host-test.log`、`bridge-smoke.log`、`android-check.log`、`android-armv7-check.log`、`build-app.log`。

新增工作流 `.github/workflows/macos-receiver.yml`；远端结果以对应提交的 GitHub Actions 为准。源码分成共享生命周期修复、Mac 平台适配、宿主绑定、原生 UI 与交付四组提交，方便 Android 分支选择性合入。

## Unified main integration (2026-11-08)

- Integrated Mac branch a9453b4 with main b43fe11 without conflicts; repository renamed to ZrimYoung/FusionPlay.
- Local validation: SDK 105 tests passed; host 8 passed, 1 existing network test ignored; cleanup 2 passed; Swift volume and brand smoke tests passed.
- CI attempt could not run: GitHub account billing restriction; macos-14 runner also rejected. Updated Mac runner to macos-15; deployment target remains macOS 14. Remote Mac build and Android compilation remain unverified for this integration.
- Later Android branch commits remain on fix/miplay-port-conflict and are not included in this integration. No new phone casting acceptance performed.

## 0.2.6 recovery and device identity (2026-11-12)

- Mac host migrates legacy identity files without changing device identifiers, chooses a private-range preferred control port, and persists the actual bound port for subsequent starts (including port-conflict fallback). Existing stale phone records are not removed.
- Sleep-stop completion now reconciles a wake/start request that arrived while the backend was busy. Device enumeration callbacks arriving after sleep/stop/termination cannot restart the receiver. Media commands are rejected during sleep and termination.
- Long-run audio and objective whole-house synchronization measurement are excluded from this round at the user's request.
- Physical sleep/wake, output removal, phone media keys and control-center behavior require live acceptance; automated checks do not establish these results.

- Validation this round: 9 ordinary host tests passed; the new live port-conflict/missing-output recovery test passed when run serially. Swift bridge passed three start/stop cycles with persisted port checks and native MediaPlayer publication/pause/cleanup. Application build and strict signature verification passed.
- Existing malformed-control probe did not observe its expected diagnostic in this environment (also failed on a serial retry); it is not marked passed. Concurrent network tests contend for fixed Lyra ports and must run serially.

- User feedback on 2026-11-12: keyboard/media control checks reported normal and receiver currently normal. User subsequently reported a missing menu-bar entry; whether this is FusionPlay's double-ring item or the system Now Playing item remains to be clarified. Menu-bar visibility is not accepted yet. Physical sleep/wake and output switching remain unverified.

- User confirmed keyboard play/pause/previous/next and system control-center media behavior normal. Missing menu-bar entries were caused by Thaw hiding them; user changed Thaw settings and confirmed visibility normal. Receiver currently normal.
- Compact menu revision adds a 56 pt cover with title/artist, a 190 pt volume row, and three footer actions (player/settings/quit). Receiver stop and logs remain available in settings; routine command acknowledgements are omitted but failures remain visible.

- Resizable player/hover mini mode: native build and strict signature checks passed. Minimum 260 × 260, expanded layout from 600 × 360; physical resize/hover appearance awaits user confirmation.

- Player refinement: expanded cover and information panel share one height and are centered as a unit; controls are bottom-aligned and title top-aligned. Mini hover overlay now includes source-reported progress/time and a blurred artwork layer fading in toward the bottom. Reduce Transparency skips artwork blur. Native build/signature checks passed; visual resize behavior awaits user feedback.

## 0.3.0 installed app (2026-11-12)

- Installed in /Applications; runtime data is ~/Library/Application Support/FusionPlay. Copied files/signature verified, identity and settings compared equal after launch, installed process reported receiver_ready. External source/build caches retained. Legacy external data/logs and previous binary remain as backups; deletion was not performed. Root launch/uninstall entries target installed app.
- Five cleanup/installation tests passed. Uninstaller syntax checked, destructive uninstall not executed on real installation.
- Mini native content aspect ratio is 1:1 and remains resizable. Keyboard focus ring disabled following user report; hover info and controls preserved.

- Final installed revision: native transparent full-size title area, no player keyboard-focus outline, ordinary hover controls hidden on pointer exit; mini window buttons fade to 22% opacity and overlays fade over 0.35 seconds (disabled with Reduce Motion). Installer tests and build/signature passed. Installed app launched from /Applications; identity/settings unchanged during update; cancellation of uninstall tested without deletion. Visual hover/window behavior still requires user confirmation.

- User acceptance on 2026-11-12: after reducing mini-player blur/dimming to the bottom third, user confirmed the result acceptable and requested GitHub publication. This confirms the current UI revision; it does not close the separately unverified sleep/wake, physical output-switching or malformed-control diagnostic checks. Long-run/synchronization measurement remains excluded by user request.

## Main integration with Windows receiver (2026-11-12)

- Resolved host conflicts against main 4f927e1: Mac identity control-port migration/persistence is macOS-only; Windows retains control-port.json and calibration. Both sets of regression tests preserved.
- Merged host tests: 11 passed, 2 explicit network tests ignored. Shared SDK: 106 passed, 1 ignored. Cleanup/install: 5 passed. Mac app build and strict signature verification passed. Windows/Android binaries not rebuilt on this Mac; prior live acceptance does not cover this combined revision.

- Post-merge UI: added a native floating/normal window-level toggle to the mini overlay. Blur mask is derived from measured controls height plus 24 pt. Native build and strict signature verification passed; installed app updated without changing runtime configuration. Pin and adaptive-blur appearance require user confirmation.

- Fixed mini backdrop geometry by attaching the full-cover blur directly behind the measured controls container; removed asynchronous preference-height state and duplicate top padding. Synthetic high-contrast renders at 260/440 pt showed a visible blur aligned above controls.
- Artwork loading now retains the previous image until replacement succeeds, with a 0.35 s crossfade and blur-to-clear transition. Disconnection/missing source/terminal failure clear stale artwork; system media does not publish old artwork while loading. Build/signature passed and installed app updated. Actual phone track-switch appearance awaits acceptance.

## Accepted mini-player refinement (2026-11-12)

- User accepted the installed progressive-blur appearance and authorized integration into main. Blur blends 6/14/26/40 pt radii across adjacent bands; coverage follows 1.35 times measured controls height. Dimming remains unchanged from the preceding installed revision.
- Larger track title, single-line artist - album metadata (omitting empty fields), tighter progress/transport spacing, and a small angled pin icon complete this UI revision.
- Native build, strict signature verification, and synthetic renders at 260/440 pt passed before installation. UI acceptance does not establish new audio, sleep/wake, or output-switching results.

## Settings pages and Mac sync adjustment (2026-11-12)

- Receiver / Appearance / Advanced / About pages; immediate Chinese/English UI preference, persistent playback-control visibility (default on), and collapsed diagnostics. Sync adjustment remains visible in Advanced.
- Mac-only signed adjustment (-200..200 ms) shifts presentation scheduling without falsifying measured hardware latency. Untimed playback retains the existing minimum safety queue. Live changes reuse the fade/realign path. Zero leaves the prior scheduling unchanged; Windows calibration and Android policy remain separate.
- Host tests: 12 passed, 2 network tests ignored. SDK tests: 107 passed, 1 ignored. Android arm64 SDK compilation passed. Native build and strict signature passed. Isolated real Swift/Rust bridge check passed default/range/persistence/reset and runtime Chinese/English resource switching.
- UI layout, audible offsets, and switching settings during actual phone casting still require user acceptance; no new long-run or objective synchronization claim.
- The earlier artwork-gap fix retains the preceding cover for up to two seconds while metadata arrives, cancels stale expiry after replacement, and clears on sustained absence/disconnect. Isolated checks passed. The mini pin action now appears at top right.

- Hover/preferences follow-up: always-visible controls, persistent pin state, and pin-button visibility default off. Settings and the mini pin button share the same stored value. Pointer exit delays hiding 0.4 s, then fades over 0.65 s; SwiftUI cancels the pending task on re-entry/disappearance. Build, strict signature, and both language resource validations passed. Visual timing and settings interaction await user acceptance.

- Sync control polish: continuous slider removes 401 native tick marks; numeric field accepts integers within -200..200, while minus/plus changes by 10 ms with bounded endpoints. The combined control was rendered at settings width to inspect layout. About artwork now uses vector SwiftUI paths, inspected at 2x scale; app build/signature passed. Live control input and audible response still require acceptance.

- User feedback on 2026-11-12: accepted the installed settings/control/icon revision and requested commit/push to main. This records UI acceptance; it does not add objective synchronization measurements or close the remaining physical recovery checks.

- App entry visibility: independent persistent Dock/menu-bar switches default on. Dock uses the native regular/accessory activation policy; the menu item uses MenuBarExtra insertion binding. Reopening (including cold launch) with both hidden exposes Settings. Build/signature validation completed; live icon visibility and reopening require user confirmation.

- Compact menu update: transport grouped beside artwork with track info; artwork/text buttons request a square mini player; thin thumb-free volume track reuses volume interaction handling. Footer retains Settings on the left and Quit on the right. Idle/playing/paused menu icons share fixed 20x16 vector-template dimensions; distinct-image and Dock-brand checks passed. Menu layout rendered for inspection; native interactions and status changes await user confirmation.

- Status-icon refinement: idle retains double rings; playing and paused use one centered ring with an internal triangle or bars. The ring uses the same radius/scale and stroke as each default ring, with unchanged 20x16 canvas. Three-state rendering inspected and brand regression passed.

- User accepted the installed single-ring playback-state revision and requested publication to main on 2026-11-12. This round includes the compact menu, thin volume track, artwork/title mini-player entry, and independent Dock/menu visibility preferences. Native build/signature, brand regression and volume-interaction regression passed; no new audio synchronization or physical recovery acceptance is implied.

## Menu progress and expandable volume (2026-11-13)

- Replaced the menu's volume line with playback progress. A footer volume button expands/collapses a horizontal thin volume control; Settings and Quit remain available.
- Connected menu click/drag seeking to the existing SDK key-seek protocol. Dragging previews only; release dispatches once. Host rejects disconnected sessions, unavailable duration, out-of-range targets, and changed track ID/title. UI does not overwrite authoritative playback position; unconfirmed/failed seeks are reported. Other player/system progress interfaces remain unchanged.
- Host regression: 13 passed, 2 network tests ignored. SDK: 107 passed, 1 ignored. Native build/signature passed. Audible seek behavior and sender-app compatibility require phone acceptance.

- Menu follow-up: volume reveal now animates a leading-anchored clipped width, replacing the slide-in transition that crossed the left icons. The menu Quit button presents localized Cancel/Quit confirmation; cancellation leaves reception running. Native build/signature and translation syntax checked; visual interaction awaits acceptance.

- User accepted the current menu revision and requested publication to main on 2026-11-13. This records UI acceptance of progress/expandable volume and quit confirmation; sender-side seek compatibility has not been separately confirmed by an explicit phone playback result.


## 0.3.1 Mac UI refinement (2026-11-16)

- Independent `feat/macos-ui-refinement` branch starts from main `720571df6a3a315a86a27937cfac15a0c26e175f`, including shared same-track seek confirmation and paused/late-seek jump guards. No additional shared audio/Android/Windows behavior changes were made for the UI work.
- Common menu/expanded/mini seeking with UI-only target preview, guarded confirmation and five-second expiry. New pure Swift tests cover stale completions, ordinary nearby ticks, backward seeks, pause, track changes, disconnect, missing duration/position and bounds. Receiver and system media retain source-reported time.
- Native resizable sidebar Settings (four existing categories), progress/time visibility and color preferences; old keys/defaults retained. Advanced sync remains expanded and diagnostics remain collapsed. Menu cover adapts within bounds and includes artist/album.
- Separate backdrop/content fades, delayed pointer exit, interaction hold, reversible transitions, clipped section-height animations, short layout crossfade and restrained button feedback. Existing 1:1 mini mode and measured 1.35x progressive blur up to 40 pt retained. Native artwork surfaces update in one animation transaction.
- Mac SDK: 114 passed, 1 explicit audio endpoint test ignored. Host: 13 passed, 2 explicit network tests ignored. Android arm64 SDK check passed with the installed NDK. Timeline, volume, brand and isolated settings/bridge checks passed; Python cleanup/installation: 5 passed.
- Isolated production-view check: 22 render cases across Chinese/English, 660/820-wide Settings, all four pages, 260/420/760-wide player layouts, hidden sections and custom color. Native sidebar row counts checked. Offscreen bitmap capture does not fully reproduce native vibrancy/glass/blur; these checks are not live mouse or phone acceptance.
- No phone casting, acoustic sync or long-run claims added. Actual hover timing, resizing, interactive preferences, rapid track changes and remote seeking require user confirmation after installation.

- Installed 0.3.1 build 11 to /Applications on 2026-11-16, strict signature verified, process running. Before/after identity/settings/sync file hashes and six existing UI preference values matched. Installed process had zero open paths on the external volume. Previous binary retained at project tmp/installed-before-0.3.1-ui-refinement.app. User accepted the installed UI revision and authorized committing, merging into main and publishing on 2026-11-16. This does not independently establish phone-side seek, acoustic synchronization or physical recovery acceptance.


## 0.3.2 歌词显示（2026-11-16）

- 已实测确认系统音乐通过 `SetMediaInfo.mLrc` 发送 Base64 UTF-8 LRC；真实内容未写入测试夹具或诊断日志。本次增加协议解码、宿主类型字段和原生歌词显示，默认关闭。
- Swift 解析测试通过：小数时间戳、多时间标签、翻译合并、正负 offset、纯文本、间奏、非法输入和资源边界。SDK 116 项、宿主 14 项通过；既有依赖实机/网络的忽略项分别为 1、2 项。Android arm64 SDK 编译检查通过，未更改音频播放策略。
- Swift/Rust 生命周期与媒体绑定、语言/设置持久化及共用跳转反馈测试通过；31 个隔离界面预览覆盖中英、歌词开关、260/420/760 尺寸、无歌词和纯文本。离屏位图不能完整呈现原生模糊与实时动画。
- 修复手动滚动后切歌经过空文档时的浏览状态继承，异步解析按曲目和来源校验，切歌/断连不保留旧词。
- 已安装内置盘 `/Applications/FusionPlay Mac.app`（0.3.2 / build 12），严格签名检查通过，单接收器进程运行；身份、接收设置、同步偏好和现有 UI 偏好校验保持一致，新歌词开关为关闭。未打开外置盘文件，旧应用保留为项目 tmp 内的回退副本。
- 本轮真实手机歌词滚动、点击歌词跳转、快速切歌与悬浮动效尚待用户实播确认；不将既往成功接收歌词等同于新界面已通过实播。不扩展到长时间播放/全屋同步验收。


## 0.3.3 歌词稳定性与窗口修复（2026-11-16）

- 用户确认 0.3.2 可显示歌词、效果不错；同时报告大窗口比例锁定、小窗口歌词覆盖封面、滚动闪烁回首、停止投送后不能缩放，以及设置侧栏展开时工具栏空圆闪现。本轮分别处理，不能把初次歌词接收成功视为这些问题已验收。
- 只读手机采样确认标题随当前歌词变化，歌手/专辑及整份歌词保持稳定，且歌词带 ti/ar/al 头。SDK 与 Host 使用稳定 ID 或歌词元数据/指纹，识别精确歌词句的标题更新，并保留同曲部分更新。没有证据证明手机发送位置 0 的占位值，因此保留合法的 0 回报和跳转。
- SDK 119 项、Host 16 项通过，既有忽略项分别 1、2 项；Android arm64 SDK 编译通过。Swift 绑定、歌词解析、稳定 ID 跳转、缺省进度保持及真实零值回归通过。
- 原生窗口检查通过：旧比例/步长释放、最新异步几何优先、封面模式方形、歌词竖向模式、手动高度保留、跨宽度边界和恢复窗口尺寸不被强制放大、宽而矮大窗口，以及模拟停止后的样式/比例修复。
- 隔离 UI 检查扩至 37 种状态，覆盖 260×440、420×700、760×400、840×300、停止投送和不同封面/歌词比例，并断言原生窗口可缩放、无比例约束、最低尺寸不随内容增长。离屏图仅检查布局，不能确认实际模糊和动态过渡。
- 小窗口封面与歌词分区可拖动，预览取消时不保存、不残留控件；设置侧栏改用固定图标，移除自动工具栏项。手机实播下的持续滚动、停止投送后手动拖动、侧栏动画和分区手势仍待用户复核。


## 0.3.4 方形封面与设置页跟进（2026-11-16）

- 用户明确要求歌词小窗口的上半区域保持 1:1，整体窗口高度用于调节下方歌词；因此撤掉分区拖动，封面区域高度直接取窗口宽度，下方最少 128 点歌词与 8 点分隔。
- 用户实测 0.3.3 的侧栏自动按钮仍出现，并叠加了新增按钮；此前原生工具栏闪现并未修复。改为 HSplitView + 原生 List，仅保留一个显式按钮，不继续依赖 NavigationSplitView 的自动项移除。
- 接收页的保存/重新连接和停止接收移出滚动表单，固定到页底。状态与提示保留在表单。
- 原生窗口最小高度回归覆盖“宽度+136”、合法手动尺寸保留及短窗口仅补足必要高度；具体原生工具栏检查、最终构建与用户实测分别记录。

- 实际 SwiftUI Window 场景确认工具栏仅有 `fusionplay.settings.sidebar`，连续三次折叠/展开原生侧栏行数按 4→0→4 变化；进一步在动画过程中采样工具栏项，独立测试不启动接收器、不改用户设置。
- SwiftUI 与原生窗口的最小高度协同，允许实测标题栏嵌入量，避免停止状态或空内容覆盖约束；最小尺寸上下界纳入界面检查。
- 追加歌词上/下边缘位置相关模糊与淡出，按行所在位置连续调整半径，小窗最高 8 点、大窗 12 点；当前句锚点为视口 0.32。此实现按行计算，并非同一长行内部逐像素变化；实际观感仍待用户确认。

- 最终 37 组中英文布局检查通过，原生工具栏在三轮开合及动画过程共 67 次采样中始终只有一个按钮；未检测到布局循环或重复状态更新警告。
- 已安装并打开内置盘 0.3.4 / build 14；设备身份、接收/同步设置及现有外观偏好校验保持一致，仅有一个接收器进程，未占用外置盘文件。旧应用保留为外置项目 tmp 中的回退副本。最终实播外观与交互等待用户复核。


## 0.3.5 侧栏与歌词过渡跟进（2026-11-17）

- 上缘模糊减轻为最高 2.5/4 点（小窗/大窗），范围 30%；下缘维持 8/12 点、范围延长为 45%。左右补足 16/24 点绘制空间并保持文字宽度，当前句锚点不变。
- 侧栏保留原生 List，固定内容宽度，仅动画外层裁剪宽度；标题改为独立 principal 项。三次开合的 67 个原生采样中，侧栏宽度单向变化，只有一个侧栏按钮和一个标题，标题中心 x=412（窗口宽820）保持一致。
- 封面首轮诊断因未及时收到投送超时退出，未取得图片。初版外层检查脚本局部变量覆盖了原哈希变量，导致保存状态检查结果无效；随后以独立配置副本复核。第二轮捕获 300×300 WebP、12974 字节，接收端解码仍为 300×300，原配置内容及字节分别校验均一致。
- 诊断只保存尺寸、格式、字节数，不保存封面或歌曲/歌词正文；正常应用已经恢复。接收端 800px 限制另以合成图片确认，此样本未触发该限制。本轮没有修改手机、封面解码或接收端大小限制。
- 用户告知另一对话正在调试手机，本轮不再操作手机；本机 UI 检查与实际安装切换分别记录。

- 0.3.5 构建、严格签名和 37 组隔离布局检查通过；原生侧栏在 67 个采样点宽度变化单向，按钮唯一、标题中心保持 x=412（820 宽窗口）。用户确认可以更新后，已安装并打开内置盘 0.3.5 / build 15；身份/接收配置/现有 UI 偏好校验一致，无外置盘文件占用。实际视觉观感仍待用户确认。


## 0.3.6 设置标题胶囊修正（2026-11-17）

- 用户截图证明 0.3.5 虽然标题位置稳定，但自定义 principal 标题被系统套入玻璃胶囊。此前计数与位置检查没有覆盖真实材料外观，因此不能视为标题外观验收。
- 仅在 macOS 26+ 对标题 ToolbarItem 使用 sharedBackgroundVisibility(.hidden)，保留侧栏按钮和现有布局；兼容旧编译器及 macOS 14/15。
- 真实原生窗口展开/收起截图均已查看：标题为普通文字，无胶囊；标题 isBordered=false，中心 x=410（820 宽窗口），67 次状态检查保持稳定。图片来自 ScreenCaptureKit.currentProcess，只捕获测试进程自身窗口，未请求录屏权限。
- 回归新增标题背景断言，避免仅凭按钮数量和坐标判定外观通过。构建与本机安装分别记录。

- 最终构建、标题无边框断言与真实窗口截图检查通过；已安装并打开内置盘 0.3.6 / build 16。身份、接收设置和现有 UI 偏好校验一致，无外置盘文件占用。


## 0.3.7 设置标题跟随侧栏（2026-11-17）

- 用户要求标题与右侧内容左对齐，并随侧栏收放移动；此前居中的 principal 标题不符合这一交互。
- 改为 navigation 普通文字标题。位置取侧栏实际动画宽度，展开时与内容文字的左边距一致；收起时保留原生窗口按钮及侧栏按钮的安全空间。工具栏本身保持固定尺寸，不随每帧布局重建。
- 保留 macOS 26 的标题背景隐藏及 macOS 14/15 兼容路径，不改接收、设备身份或音频策略。

- 真实原生窗口 73 个采样通过，覆盖三轮收放动画及 660/1000 点宽度；展开标题起点 203，收起 136，始终避让侧栏按钮。实际文字绘制空间与内容同时检查，避免位置通过但标题被截成省略号。
- 展开和收起的真实截图均已查看：标题完整显示，保持普通文字、无胶囊。最终构建及严格签名检查通过，已安装并打开内置盘 0.3.7 / build 17；设备身份、接收设置和已有 UI 偏好保持一致，单接收器进程、无外置盘文件占用。


## 设置导航的侧栏与顶部布局（2026-11-17）

- 根据 iPad Apple Music 参考图，为 Mac 设置提供两种导航布局。使用原生 List、工具栏及 segmented Picker 组合，未将 iPad 的系统自动转换能力当作 Mac 既有能力。目标系统仍为 macOS 14+。
- 侧栏开关保持窗口左上角单一入口，展开显示侧栏与左对齐标题；收起改为顶部四页选择。共用同一页面 selection 和内容树，保存导航布局偏好，不改接收、音频或设备身份。
- 本轮只修改设置导航及对应检查，保留同目录其他对话进行的歌词/播放器修改；构建、安装与原生截图结果另记。


## 0.3.8 歌词模式、页面留白与原生全屏（2026-11-17）

- 增加 automatic/always/never 三种显示策略；旧 playerShowsLyrics 显式布尔值迁移并保留原键，新安装默认自动。实际设置迁移以本机安装后的独立回读为准。
- 有效歌词依据解析后的行文档，支持 LRC 和纯文本；前奏、间奏、暂停不隐藏。解析替换期间保留可见性，空曲目和断连清除；合成测试涵盖迟到歌词、有歌词切到有歌词、无歌词及断连。
- 大窗水平内边距从 28 点改为随宽度 36–48 点。44 组隔离生产视图检查通过，已查看英文最小设置窗口及 1200×800 歌词窗口，选项完整、留白正确。离屏位图只用于布局，不作为材料模糊效果的实机验收。
- 窗口显式支持 accessory 模式主全屏；全屏进出过程中释放方形和最小高度约束，暂缓强制尺寸，退出按实际几何恢复并保留置顶偏好。原生隐藏窗口生命周期模拟通过；真实 Space 进出及最终安装分别记录。
- 标题变歌词另行只读分析：Mac 直接显示 snapshot.title，SDK 的 caption 识别仅严格匹配定时歌词行，恢复主要依赖 [ti:]。首次已有错误标题而缺少 [ti:] 时，Host 的非空更新可能保留错误标题；目前未获取用户该曲原始字段，不能确认具体触发分支。本轮未更改标题恢复策略或增添其设置。

- 独立合成窗口真实进入/退出 macOS 全屏 Space 通过：accessory 应用 360×360 → 1710×1074 → 360×360，退出后方形比例与置顶恢复；未操作手机或原接收器。
- 真实菜单的 ⌃⌘F 唯一性检查通过。完整设置工具栏检查遇到并行任务新增“侧栏收起后分页标签”的修改，原始标题常驻断言因此失效；保留并行任务最新测试，不覆盖其实现。后续整套运行在中文第3页页签状态遇到侧栏仍在展开的失败，尚未归因，不能记录为工具栏回归通过。
- 已安装并打开内置盘 0.3.8 / build 18；独立回读显示旧歌词开启迁移为 always，设备身份、接收/同步设置及其余 UI 偏好保持一致，单接收器进程，无外置盘文件占用。旧版回退副本位于项目 tmp/installed-before-0.3.8-lyrics-mode-20261117-231026.app。

- 最终原生窗口检查 99 个采样通过，覆盖原有 67 个动画采样、中英两种语言、660/1000 点宽度及真实 NSSegmentedControl 四页点击往返。标题与顶部导航在稳定态互斥，始终只有一个侧栏开关，四页选中状态同步。
- 已查看五张真实窗口截图；中英文顶部标签完整，英文侧栏/标题/正文一致。侧栏语言采用截图人工核对，未把无法读取的 SwiftUI 虚拟行文字当作自动验证成功。测试宿主补齐与正式场景一致的 locale，原生 List 仅在语言变化时刷新身份。
- 最终签名构建已更新到内置盘应用（保留同目录其他任务的 0.3.8 / build 18 版本）。安装二进制与本轮构建哈希一致，原设备身份、接收/同步设置及现有外观/歌词偏好校验一致；单接收器进程，无外置盘文件占用。未操作手机或提交 Git。


## GitHub 发布前检查（2026-11-17）

- 复核 SDK 119 项、Host 16 项通过；既有忽略项分别 1、2。Swift 歌词解析、三模式/旧设置迁移、进度保持、原生窗口全屏约束与跳转时间线五组脚本通过。
- 独立读取最终 settings-toolbar-check.json：passed=true、99 个采样、5 张截图；之前工具栏测试未通过的中间记录已由此最终结果覆盖。
- Flutter 分析/测试依提交指引使用已有工具与 --no-pub 尝试；此独立 Mac 克隆没有 .dart_tool 依赖配置，工具启动长时间无输出后已仅停止本轮检查进程，未获得分析或测试结果。Kotlin 单元测试离线尝试因缺少 flutter/android/local.properties 在配置阶段退出；未重建 Android APK或声称通过上述检查。
- 共享协议审查保留已知限制：无显式曲目 ID 且 headerless 歌词首次迟到时，SDK fallback identity 仍可能变更、影响进行中的控制确认；稳定 ID 路径已有回归。歌词标题恢复仍依赖真实歌名来源，不能宣称完全解决发送端 caption 标题。
- Mac CI 增加 feat/macos-lyrics 推送触发；远端执行结果另行核对，不以本机结果替代 GitHub Actions 结果。


## 0.3.9 设置动效、材质与播放页留白

- 大窗口边距随宽度渐增：600 点为 36、760 点为 52、892 点为 65.2、1040 点及以上为 80；不改变封面尺寸上限、mini 方形模式或竖向歌词分区。
- 移除手动浏览歌词的回位按钮，停止滚动 5 秒后按最新播放位置回到当前句。拖动/取消、惯性事件延后计时；切歌、断连与消失撤销旧请求，VoiceOver 和减少动态效果遵从既有策略。独立类型检查通过，真实手动浏览的听播交互仍需用户复核。
- 设置采用分阶段淡出/几何变化/原生布局确认/淡入。共享选择与详情内容身份不变；递增代次拦截旧回调，增加取消发生在 Task 首次执行前和 Reduce Motion 的回归。Window Scene 用原生 unified(showsTitle:false) 保持系统标题隐藏，避免转场更新重置可见性。
- 左侧使用单一 NSVisualEffectView.sidebar/behindWindow 材质延伸至 titlebar，原生 List 隐去重复底色。外观页的 4 处宽分段改为原生 menu Picker，保留 11 个设置键、默认值、Dock 即时生效及独立置顶按钮偏好。

- 最终 118 个原生窗口采样通过，涵盖快速双向反转、五连按、两种语言/窗口宽度、单一侧栏入口和选中页保持。取消发生在 Task 首次执行前与 Reduce Motion 的模型回归通过；中间帧和稳定态真实截图均已查看，材质连续、无重复标准标题、整个玻璃胶囊同步淡出。
- 50 组生产视图布局通过；已查看中英文最窄外观页和 892 点歌词窗口，菜单完整、两侧留白增大。离屏布局图不用于证明真实材质与模糊，材质依据另一个原生 Window 场景检查。
- 最终构建及严格签名检查通过，已安装并打开内置盘 0.3.9 / build 19。安装二进制与本轮构建哈希一致，原设备身份、接收/同步设置及原有外观和歌词偏好校验一致；单接收器进程，无外置盘文件占用。未做手机操作或 Git 提交/推送。


## 0.3.10 字体与播放器显隐（2026-11-18）

- 大窗封面/歌词间距由 32 渐进到 48 点，600 点宽保留 32、760 点及以上为 48；保留 0.3.9 的窗口两侧留白。歌词开关改为常驻阅读视口与同一封面/详情布局收放，避免整棵视图替换。
- 进度填充原有独立 animation=nil transaction，使其宽度跳变而背景继续布局动画；改为与背景共享边界的 Shape，fraction 本身不参与插值。没有改动手机跳转请求、回报确认和音频路径。
- 新增全局字族/字重偏好 uiFontFamily/uiFontWeight，默认系统/400；只列本机实际字体面，缓存解析，保留缺失字族并回退。外观页的原生折叠区含字族搜索、可用字重、双语与数字预览、恢复默认。字号和强调层级保留，SF Symbols 仍用系统字体。
- 正式 0.3.10/build20 构建及严格签名通过；字体解析检查覆盖实际安装字族/非斜体面、最近可用字重/并列取轻、系统九档语义、缺失字族保留及缓存；无新依赖或字体下载。
- 82 张生产视图布局图通过，保留原 50 例，增加中英文、自定义/缺失字体、600/892 宽边界；64 个同 host 中间采样确认进度/歌词开关期间原生滚动视图身份不变，布局不越界且不引入大窗比例锁。已查看代表截图，离屏图不作为真实模糊或完整动效的实机验收。
- 设置原生工具栏 118 个采样及 6 张自身窗口截图检查通过，覆盖连续开关、反转、语言、宽度和唯一菜单项；已查看展开截图。
- Windows v3 原型在独立本机 Playwright/Edge 上实际点击核对，验证显示开关关联颜色区域、字体折叠/字族/字重、接收草稿应用与按输出设备保存偏移；未出现脚本错误。该静态原型操作只写隔离浏览器状态，不读取或修改接收器/手机/真实系统网络音频设置；字体例表并非 Mac 实际字体渲染证据。

- 字体选择区的额外原生点击尝试未完成：SwiftUI 虚拟折叠控件未响应进程内 AX press 或限定到自身窗口的鼠标事件，不能据此记录搜索、选择、字重和恢复默认交互通过。隔离宿主编译及收起摘要截图已检查，原始 AX 树/截图留在 artifacts/font-settings-check.*；该环境相关试验源码保留在 tmp，不纳入 CI 或交付源码检查。字体交互仍需人工复核。

- 最终字体缓存按 512 项限制，避免连续缩放产生无限字号缓存；收尾后重新构建、严格签名和字体解析检查均通过。已安装并打开内置盘 0.3.10/build20，安装程序独立核对设备身份、接收/同步设置及现有 UI 偏好均一致，只有一个接收器进程，外置盘打开文件为 0。安装报告为 tmp/player-font-0310-install-verification.json；旧版保留在项目 tmp 的回退副本。本轮未操作手机或提交/推送 Git。


## 0.3.11 切歌高度、约束崩溃与显示标题（2026-11-18）

- 用户报告切歌缩短歌词区并提供两次 0.3.10/build20 主线程崩溃。系统日志确认窗口约束更新计数超过限制；栈处于 NSHostingView.minSize/updateWindowContentSizeExtrema/图 transform 再次失效。0.3.10 的离屏和开关检查没有覆盖新曲空首帧至歌词晚到，不能作为切曲稳定性验收。
- 保存未修复源码及 SHA256。真实 Window Scene 基线105阶段出现13次高度违例：automatic 420×800→空歌词420×420→晚到420×693，三轮复现。受控基线未复现崩溃，不能声称取得相同崩溃的负/正对照。
- 移除 geometry.width→State→根 minHeight 的反馈。公开 sizingOptions 接管尝试中，Scene 首帧为0、之后恢复1；最终删除该尝试，由 SwiftUI 保持固定260 minimum，原生仅检查实际几何并必要时补足歌词区。全屏、方形封面与设置窗口规则保留。
- 新曲元数据空档清旧正文并等待最多2秒，晚到、跨曲、断连与终止取消旧任务；超时仍空则自动隐藏。窗口记忆手动歌词区域高度，经过无歌词阶段后也恢复。
- 最终真实 Scene 保留原157阶段，追加75.15秒/74轮合成切曲和封面动画，共544 checkpoint、0尺寸违例，进程95.78秒正常退出，无约束循环/异常日志。包含always/automatic、420×800/500×900/892×650以及2/8/24/64/128行歌词。原手机操作和长期实播仍需用户确认，不据此宣称彻底排除崩溃。
- 84张生产布局图、64个同host开关样本、真实模型的晚到/超时/重复空帧/跨曲/断连取消回归通过；原生比例、固定minimum及全屏策略回归通过。
- 默认关闭的标题修正通过45组合成案例，要求可信元数据与歌词证据，标题变化快并非充分依据。MediaPresentation控制标识与原Snapshot未变，菜单及播放器合成截图已查看。暂停时偏好变化会显式刷新系统媒体。没有获取该手机歌曲的LRC头，截图歌曲的实际恢复尚未实播验收。
- 0.3.11/build21 已构建、签名和安装，设备身份、接收/同步配置及旧UI偏好独立校验一致；automatic模式保留，只有一个接收器进程且无外置盘打开文件。回退副本和安装报告在项目tmp，未修改手机数据。

- 发布前共享SDK 119项、Host 16项通过（既有忽略项1/2）；本机PATH没有Flutter且此克隆缺少package_config/local.properties，Flutter检查未运行。Android离线单元检查因缺少Java Runtime启动失败，未安装额外工具链，也未宣称Android构建通过。本轮没有修改共享Rust/Android运行代码。


## 0.3.12 空状态与导航符号（2026-11-18）

- 播放器以当前媒体会话及曲目信息判断空状态。无歌曲时只渲染音符和原生毛玻璃；进度、标题/专辑及播放按钮偏好不被改写，有歌曲时按原设置恢复。未改变窗口 minimum、比例、歌词高度恢复或音频路径。
- 84 组生产视图、64 个同 host 显隐采样及歌词元数据空档检查通过。另用独立真实 Window Scene、420×420 空媒体状态，强制所有播放控件偏好开启：内容播放控件为0，窗口 isOpaque=false、背景 alpha=0，唯一可见材质为 behindWindow/HUD/active，覆盖整个窗口。自身窗口截图已查看；单窗口图为均匀底色，不能据此证明桌面背景细节的实际模糊观感。
- 四个导航入口均使用官方系统符号，统一14点常规笔画和18点对齐槽。最终构建和严格签名通过；已安装打开0.3.12/build22，身份、接收配置及UI偏好校验保持一致，安装二进制与构建一致，进程仅一个，无外置盘打开文件。临时预览已退出，工具与图片保留在项目tmp/artifacts，未操作手机。


## 0.3.13 菜单背景选择（2026-11-18）

- 新增默认保留当前系统外观的菜单背景偏好，支持毛玻璃与液态玻璃。仅在毛玻璃分支添加原生 behindWindow/popover 内容背景；液态分支不叠加额外玻璃。背景不拦截点击，保留原 MenuBarExtra 的边框、定位、阴影与生命周期，未改播放器几何或音频路径。
- 官方 ContainerBackgroundPlacement.window 的保证范围为 Window/WindowGroup。独立 MenuBarExtra 容器实验没有完成有效截图对照，不能宣称该 API 已验证可替换系统容器；产品实现采用内容背景，不修改私有系统视图或重写状态栏生命周期。
- 构建及严格签名通过；86组生产视图布局、64个同host采样和真实预览模型歌词空档检查通过，新增两种菜单背景预览已查看。离屏图仅用于内容及布局，系统弹窗外框与完整材质观感仍需实际菜单查看。
- 已安装并打开0.3.13/build23，安装二进制与构建一致，设备身份、接收配置与UI偏好独立核对保持，只有一个接收器进程且外置盘打开文件为0。安装报告位于tmp/menu-panel-0313-install-verification.json。没有修改手机或用户的系统外观设置。

## 0.3.14 清透玻璃与菜单生命周期（2026-11-18）

- 原先的液态选项保留了系统菜单厚背景，无法达到用户要求的清透程度。现在使用公开 NSStatusItem、透明 NSPanel 和单个原生 NSGlassEffectView.style = .clear，无额外染色/暗色底层，不叠加原系统菜单玻璃。毛玻璃、旧系统和减少透明度路径保留。
- 同一 NSHostingView 在材质切换间保留，Scene 的打开窗口动作由播放器/设置注入；设置独立恢复也能创建入口。状态栏级别避免被普通浮窗遮挡，稳定 autosaveName 记忆位置。屏幕边界定位、点击外部、Escape、退出确认期间保持父面板、反复启停/隐藏入口、回调更新和重复释放均通过隔离原生检查。
- 84 组生产视图布局、64 个同宿主布局采样及歌词 metadata gap 检查通过。新增的原生材质截图已查看，但当前测试进程没有屏幕录制权限，只捕获自身窗口：窗口独立截图不包含桌面透射，不能作为亮暗桌面背景上的最终观感验收；未申请额外权限。实际观感留待安装后用户查看。
- 本轮不改变音频处理、手机设置或接收器身份。

## 0.3.15 移除额外歌词分隔线（2026-11-18）

- 已定位小窗口显式绘制的 0.5pt、6% 白线：它居中放在 8pt 间隔内，视觉上比封面边缘低约4pt。替换为相同高度的透明间隔，保留歌词区和窗口尺寸计算；不调整模糊层位置或封面坐标。
- 构建与严格签名通过，已安装并打开 0.3.15/build25。安装产物与构建一致，设备身份、接收配置和UI偏好校验一致，接收器进程仅一个，无外置盘打开文件。报告：tmp/cover-seam-0315-install-verification.json。清透菜单的原生交互检查与现有布局检查结果见0.3.14记录；本次淡线删除保持相同8pt布局，不以此宣称手机实播验收。

## 0.3.16 歌词横向换行（2026-11-18）

- 已定位每次视口size变化立即执行禁用动画的scrollTo，与换行高度变化叠加造成闪跳。现在原生live resize期间抑制跟随，停稳180ms后仅跟随一次，异步任务通过最新视图回调读取最新播放位置。浏览、拖动与旁白状态保留。
- 原文/译文使用Core Text UTF-16换行范围判定排版变化，实时SwiftUI Text保留；最多一张旧排版过渡图，限制每张2M像素/4096边长，测量缓存96项，布局高度与淡变约0.22秒同步，减少动态效果时无动画。
- 专项隔离检查通过：三种辅助功能配置、39个连续宽度采样、同一NSScrollView保留、live resize期间跟随0次、结束后仅1次（旁白0次）、手动浏览不被重定位打断；覆盖中英文、emoji/组合字符、多段落和RTL测量。自身窗口实际合成截图已查看，400/520pt最终文字与翻译完整。离屏缓存的过渡重影不能代表合成结果，实际截图使用仅本进程窗口的ScreenCaptureKit，不申请屏幕权限。
- 0.3.16/build26已构建、严格签名、安装并打开，身份/接收配置/UI偏好及二进制一致性校验通过，仅一个接收器且外置盘打开文件0。临时开启播放器窗口诊断用于另行排查全屏；诊断默认关闭，上限1MiB且不记录曲目/文本，不代表全屏问题已修复。

## 0.3.17 恢复绿色按钮原生全屏（2026-11-18）

- 实际0.3.16在快捷键触发时 collectionBehavior=66048，包含fullScreenNone，没有进入通知；原生适配临时改回65664后又被SwiftUI自动规则覆盖。使用macOS15+公开windowFullScreenBehavior(.enabled)统一声明，未替换绿色按钮动作、窗口delegate或系统快捷键；macOS14旧策略保留。
- 隐藏真实Window回归25个采样通过：自动模式66048，显式启用后24个采样稳定65664（含缩放），未进入Space。84组布局、64个连续显隐采样和歌词专项检查通过；真实Window媒体/几何生命周期20.78秒、0退出码、无超时。
- 0.3.17/build27已安装且身份/设置/二进制校验一致。用户反馈全屏可用，并提供全屏截图；实际窗口1230记录完整will/didEnter和will/didExit，fullScreen=true、层级normal，退出恢复原1259×807窗口；之后再次进入也正常。全屏原生进入与退出已确认，不能据此代替长期播放验收。

## 0.3.18 全屏歌词比例布局（2026-11-18）

- 原inset80pt/专辑列330pt/列间距48pt上限导致大窗口新增宽度几乎全部进入歌词区。改用居中内容区、比例边距、平滑变化的专辑比例、比例间距；超宽阅读内容上限1440pt。1710宽时边距约171、专辑/封面约486、列间距约89、歌词约793；2560宽时居中留白560、专辑约512。实际封面始终受窗口高度与显示控件预算限制。
- 无歌词布局和迷你比例保持；隐藏歌词区仍使用同一个阅读宽度，保留AnyLayout与滚动身份。不向窗口最小尺寸或比例发布布局测量值。普通窗口边距只增加不缩小，矮窗口封面与标题/进度统一左对齐。新版正常启动不再传入临时全屏诊断环境变量。
- 最终28组纯几何检查、88组隐藏生产视图布局、64个同宿主显隐采样通过。包含1710×1112、2560×1440预览，已查看全屏静态布局图；静态离屏图用于几何核对，不作为透明度/模糊合成验收。0.3.18/build28已安装并打开，设备身份/接收配置/UI偏好和二进制一致，接收进程仅一个、无外置盘打开文件；安装入口未传入临时诊断变量。

## 0.3.19 iPad 原生歌词动效与设置详情（2026-11-18）

- 参考实际 FusionPlay iOS/iPad 分支 feat/ios-receiver c6520c10c8d23badc88c0a8ba710bada2a74eab5 的 LyricReflowText.swift、ReceiverRootView.swift；未修改该工作区。Mac15+ 使用原生 TextRenderer/CharacterIndex 字簇、480ms换行、190ms同行位移及最大4pt模糊。跨行时先淡出、分阶段调整行高后再淡入；反向从当前呈现状态重定向。同一行位移保留平滑运动。
- 行高只有原生 Text 的 intrinsic geometry 一个来源，测量置于动画 frame 之前；Text.Layout 的字形边界仅用于判断方向。过期任务也清理计划，空闲 Timeline 暂停。超过1024字节的长行使用普通原生 Text；减少动态效果/旁白不运行换行动画。Mac14保留有界 CoreText 字词回退，未使用截图链。
- 原生专项检查确认真实 Text.Layout 已收到宽度变化；缩窄/放宽的模糊阶段、行高顺序、同行插值、反向缩放、静止后高度稳定、自定义字体/Unicode、动效中途开启减少动态效果均通过。自身真实 renderer 的 ImageRenderer 阶段图已查看，不读取桌面或其他应用。最初620→330样例没有同排重叠字形，增加620→560样例后才实际覆盖同行位移；回退路径相同样例修正后通过（第一次回退测试断言退出只发生于独立检查进程）。
- 回退排版28组Unicode/连字/表情/RTL/长词/缓存界限检查通过，41种固定字体宽度约14ms。回退动效强制路径通过分阶段高度、同排位移、反向缩放和减少动态效果；这不等于在macOS14实机验收。
- LyricsView 保留真实 NSScrollView；三种辅助功能配置与39个连续宽度采样通过，缩放中跟随0次、停稳仅一次（旁白0次），不打断手动浏览。等待文字完成后420ms跟随32%锚点；显隐保持同一视图，360ms透明度与12pt纵向位移，内层reading size不叠加父布局动画。
- 设置字体/同步诊断均为默认关闭的原生sheet入口。隐藏真实窗口检查通过字体行的公开辅助功能点击打开、Close/Escape/CmdW仅关闭sheet、字体偏好不变、520pt宽及随屏幕限高；headerView/withinWindow、原生位置、渐变方向、鼠标透传、减少透明度回退通过。未将离屏Form图作为完整工具栏材质观感验收。
- 完整构建和严格签名通过；88组生产视图、64个同host显隐采样及真实预览模型元数据空档检查通过。包含全屏/超宽、紧凑布局、自定义与缺失字体。共享Rust及手机数据未修改，未运行声学延迟或长时间实播。
- 三种菜单材质的隐藏原生检查通过：磨砂使用NSVisualEffectView且保留窗口阴影，regular/clear使用单个NSGlassEffectView且无额外窗口阴影；同host、旧liquid映射与偏好保持均通过。默认检查不order窗口、不抢焦点、不截图；交互与退出sheet未重新运行。初次隐藏测试对窗口排列/焦点的断言失败，只调整测试为完全不显示窗口后重跑通过，生产实现没有因此改变。系统玻璃自身光学轮廓仍由系统管理，真实通透观感需用户查看。
- 已安装并打开0.3.19/build29，独立读取安装包版本和二进制hash与构建产物一致；设备身份、接收/同步配置与全部UI偏好一致，仅一个内部盘应用进程，外置盘打开文件0。更新报告：tmp/ipad-motion-0319-install-verification.json；保留更新前0.3.18应用用于回退。实际投送后的观感与连续缩放仍等待用户确认。

## 0.3.20 可调交错滚动与正文顶部模糊（2026-11-18）

- 用户指出0.3.19未包含iPad可调时间的交错滚动，已确认：此前只移植字形换行动画，未连接逐行时间与滚动wave。现新增“外观 → 歌词动效”，默认开/140ms，0–240ms、10ms步进，同一偏好影响实际滚动和换行。连续轨道在绑定中量化，避免原生stepped-slider刻度纹理；关闭保留上次时间。
- 使用iPad相同32档可见行排序、420ms smoothstep与36pt波形。常规相邻歌词推进创建正/反向wave，浏览、缩放、换文档、断连与辅助功能取消wave，结束清理Timeline。glyph延迟上限由140提升至240ms，停稳跟随等待duration+实际span+50ms；不修改音频同步。
- 纯数学990采样通过，覆盖0/140/240ms、钳位、行排序、方向和起止归零。真实LyricsView检查通过distinct环境延迟传入、240ms正反向wave、wave结束清理、同scroll保留、39个宽度采样与三种辅助功能配置。
- 实际原生TextRenderer的240ms用例通过：180ms旧坐标/全可见无模糊，340ms开始模糊，380ms行高仍旧，460ms行高移动且跨行文字隐藏，620ms淡入，820ms停稳。保留此前0delay全套用例；截图在采样后渲染冻结preview，避免截图耗时影响时序。
- 设置模糊从全窗口移至右侧正文顶部56pt，材质withinWindow/headerView/active，未叠加自绘颜色层。0–44pt滚动偏移控制平滑显现，顶部完全透明；侧栏、toolbar标题、系统窗口按钮在效果范围外。减少动态效果将显隐时长归0；减少透明度使用纯色回退。
- 隐藏真实Form检查通过滚动0→22→90→0、回顶归零、页面替换时旧observer解除/新页顶部透明、nativeframe不交sidebar/toolbar/窗控，以及字体sheet Close/Escape/CmdW。测试窗口透明、未操作其他应用。隐藏原生检查证明材质/层级/滚动规则，不能替代系统最终合成的实际模糊强度观感。
- 新设置的公开辅助功能实测通过：默认开/140ms、原生slider范围0–240，设197立即量化保存200，增量动作变210；关闭/开启真实checkbox后slider隐藏/恢复且210ms保留。测试使用独立偏好域及透明窗口，未修改正式设置；checkbox动作返回值不可靠，最终以真实偏好和控件显隐校验。
- 完整构建与严格签名、88组生产视图、64个同host显隐样本与元数据空档检查通过。未改音频链路、手机或iPad工作区。
- 已安装并打开0.3.20/build30，独立读取版本和二进制hash一致；已有UI偏好、设备身份及接收/同步配置保留，仅一个内部盘接收器进程，外置盘打开文件0。新增设置允许首次采用true/140ms默认；未覆写任何已有键。报告tmp/lyrics-stagger-0320-install-verification.json。实际模糊合成观感待用户查看。

## 0.3.21 歌词字号、移动时长与阅读定位（2026-11-18）

- 交错时间扩至0–1000ms，保留默认140ms/10ms步进；主文与翻译字号同比缩放75%–200%，默认100%/5%步进；单行滚动移动100–1500ms，默认420ms/10ms步进。全局界面字体与恢复默认字体行为保持独立。
- scrollTo与滚动wave共用实际移动时长；波形end=duration+span。连续推进只保存33个当前位移采样，重新接续起点连续、范围限制±36pt，不递归保留旧波。resize尾波以180ms收回旧视觉位移。纯计算6435组合及26400次连续中断检查通过，覆盖默认/边界参数、正反方向、起止及尾波。
- 实际Native TextRenderer的原零延迟、240ms和新增1000ms都通过；1000ms例800ms仍保持旧形，之后按预期模糊/行高/淡入，最终停稳。
- 公开AX的隔离设置检查通过：字号167→165%、移动837→840ms，各设置独立即时保存；跨度范围0–1000、10ms增量与开关保值通过。首次SwiftUI惰性AX树未初始化，只查询自身公开AXWindows后即可读取，无产品绕路或额外权限。
- 用户报告横向缩放后上下滑移。真实同一当前句基线：初始句首180pt，拖住时阅读锚点误差从约21.6pt增至293.4pt（相对漂移约272）；释放后animatedscrollTo回弹约272；scroll身份未重建。新增弱引用原生阅读锚点，补偿NSClipView.origin的行高重排位移，不发布窗口minimum/比例或更改行尺寸。同一句保持时取消多余整屏回位。默认档量测句首180→180→180pt，settling期间相对漂移0。
- 阅读锚点专项默认与最大档通过：同句读点漂移约0，缩放中换句只跟随最新id一次，手动阅读保持，VoiceOver不进行原生pin；晚attach重试与绑定所有权清理已覆盖。新增`LyricsViewportAnchor.swift`只维护弱引用行视图及clip origin，未改窗口尺寸约束。当前句高于视口60%时不对整块统一模糊，保留边缘mask，避免200%字号把当前句整个压糊。
- 最大1000ms/1500ms/200%真实LyricsView集成检查通过；0.3.21首次构建与严格签名通过。用户随后明确要求设置顶部无色层的纯blur，并提供原生header材质仍有颜色/标题穿透截图，因此暂未安装该构建；设置顶部效果继续修正，不能把此前材质属性通过当作视觉模糊验收。
- 最终设置顶部采用公开NSView.contentFilters/CIMaskedVariableBlur直接处理正文，无NSVisualEffectView材质、颜色fill、fallback色层或截图刷新。实测原生NSTextField/Toggle与真实SwiftUI grouped Form都得到纯blur，独立CALayer均色对照RGBA [146,146,146,255]保持，真实Form的纹理锐度显著降低。
- 生产同一makeFilter代码的真实Form像素对照：offset0 filters=[]、图像完全相同；offset90顶部锐度9.177→1.3155，底部32.765保持，独立查看raw/production正向PNG确认文字渐变变糊，未染色。负对照验证不能按docHeight翻Y；采用公开convertToLayer坐标。
- 查到旧mask范围偏移：clip.bounds高500包含52pt标题区，而clip.visibleRect仅448；旧56pt效果仅4pt作用于可见正文。现右列明确.clipped、mask取visibleRect，hidden原生窗口band=(160,392,500,56)，顶端448等于contentLayout安全上界，sidebar与toolbar不在正文/滤镜中，内容标题不会穿进native标题。
- 最终隐藏设置检查通过零偏移无滤镜、中间/最大半径、reduceMotion即时、reduceTransparency移除而非加色层、页面换绑恢复原CIFilter对象及字体sheet键盘行为。92组生产视图和64个同host样本通过，已独立查看200%字号英文compact/full图，当前句清楚；中文对应布局渲染检查通过。最终纯blur版本全量构建和严格签名通过；其他未改动的音频/手机/iPad工作区不在本轮变更中。
- 最终0.3.21/build31已安装并打开，独立读取版本和二进制hash匹配最终纯blur构建；UI偏好、设备身份及接收/同步配置保留，仅一个内部盘接收器进程，外置盘打开文件0。报告tmp/lyrics-reading-0321-install-verification.json，保留0.3.20用于回退；实际手机投送与最终桌面合成观感待用户确认。


### 0.3.30 窄宽窗口的对应元素迁移

600pt 窄宽布局切换不再整体淡入淡出。主封面、歌曲信息、进度、三个播放按钮和当前可见歌词区按各自几何位置衔接，使用 response 0.52、dampingFraction 0.88 的原生弹簧；持续缩放和反向缩放直接重定向当前动画。非活动分页和歌词页小封面不共享主元素的匹配 ID，减少动态效果时直接切换布局。

匹配修饰器保持固定结构，非活动元素使用每实例独立 ID。圆角、边框和阴影跟随封面移动；迁移期间暂时放宽局部裁切，800ms 后恢复，旧清理任务在反向时取消。分页外边界仍裁切；底边歌词拖动继续禁用布局动画。歌词内容原有尺寸动画屏蔽保留在匹配效果内侧；匹配几何不等于跨根布局保留同一个原生歌词滚动视图。

全源码离屏播放器回归、正式构建和严格签名检查通过。后台安装确认 0.3.30 / 40、单实例，settings.json 与 identity.json 校验值保留。所有新检查不排序或激活窗口，不采集桌面。cacheDisplay 读取模型树，不能把离屏最终布局检查视为实际动画中间帧或主观流畅度验收；实际桌面动画观感仍待确认。

新增 `test-player-responsive-motion.sh`：完全不排序的真实 PlayerView 离屏检查覆盖封面/专辑两种模式、歌词开关及动画事务启用/禁用，共 8 个组合；520→760→520 双向往返和快速反向后的红色封面标记、绿色进度完整度均通过，未出现重复 isSource 警告。该检查不更改系统“减少动态效果”，也不把禁用动画事务等同于覆盖系统无障碍环境分支；中间合成动画仍标记为 INCONCLUSIVE。


### 0.3.30 实测补充与 0.3.31 持久布局

用户实测 0.3.30 宽窄切换仍跳变，没有预期元素迁移，并反馈歌词滚动卡顿。上一版仅通过最终离屏布局，未证明中间动画，不能据此判定动效成功；匹配几何和整块歌词包装现已撤除。只读短时采样看到 SwiftUI 布局与文字测量开销，不能据此认定唯一卡顿原因。歌词接收、解析、内容与时间同步本轮未改。

0.3.31 使用单一持久画布：主封面、歌曲信息、进度、三个播放按钮及唯一歌词视图固定身份；纯几何生成宽窄和分页端点，显式临界阻尼弹簧更新位置、尺寸与外观。公共运行模式的60Hz计时器可在原生窗口跟踪模式推进，仅在过渡期间运行；反向保留当前坐标和速度。歌词只在实际宽高变化时保锚，控件透明度和翻页平移不暂停跟随；隐藏摘要暂停刷新。

短专辑页保留原生播放滚动容器，透明标记仅通过真实 enclosingScrollView 标识它；歌词绑定排除该播放容器，保持自己的原生 viewport。元数据限制在当前插值框内，换行和歌词页头选项纳入过渡；隐藏进度不保留鼠标翻页排除区域。歌词页鼠标横拖放行歌词行，保留实际控件与文字选择的优先级，通过延迟点击和手势失败依赖避免翻页同时发出歌词点击。后台隐藏启动后，用户点击应用或菜单入口会显式解除隐藏。

正式构建、严格签名和原有全源码静默播放器回归通过。严格8组真实PlayerView离屏检查（两模式、歌词开关、驱动动画开关）：启用动画每方向采到3至4个不同的真实位图位置和尺寸，禁止只验证透明度或终点；禁用驱动动画直接收敛。非线性、反向位置及速度连续、单一封面实例、同一正确歌词滚动容器、歌词页返回、静态滚动无额外画布计时器、eventTracking模式推进与结束释放均通过。普通和翻转坐标共72项离屏手势检查通过。

检查不排序或激活窗口、不发送系统输入、不截取桌面、不启动接收器、不更改系统减少动态效果；禁用驱动分支不等同切换系统辅助功能设置。实际桌面帧率、手机歌词滚动手感和鼠标拖动仍需实播复测。


### 0.3.32 动画排版开销与菜单四角

用户实测 0.3.31 已能看到移动，但明显卡顿，并反馈菜单圆角外有矩形灰底。只读采样及独立基准确认：动画发布整个 pose 会重算父页面、反复测量元数据，并把弹簧中间宽高不断传给原生歌词排版。正式版现在由根视图仅持有驱动引用，各轻量 placement 单独观察动画；歌词和元数据使用稳定的目标排版，位置、裁切或绘制缩放跟随弹簧。图片与渐进模糊内容也固定目标尺寸后变换，按钮和进度保留实际命中尺寸。歌词解析、时序和逐词换行逻辑未改。

元数据测高增加锁保护的256项FIFO缓存，完整精确键覆盖文字、字族/字号、宽度、间距、换行及行数预算；保留原有 CoreText 与 CJK fallback 算法。定向布局和命中/淘汰检查通过。

同一 fixture、FFI、编译参数及60次轨迹对照（全部离屏，测量阶段不读取位图）：连续宽度 CPU 3.466→0.991秒、布局p95 131→29ms；宽窄弹簧 CPU 2.389→0.201秒、p95 151→11ms；翻页 CPU 0.522→0.109秒、p95 13.7→5.0ms。各段均保持同一歌词滚动容器。连续宽度仍有31/60次布局超过16ms；这是包含UI测试相位采样的CPU/布局吞吐测量，不是正式版屏幕帧率，也未证明全程60FPS。phaseBoundaries只来自测试宏，正式版不承担该采样任务，不能将其直接当作生产热点。对照报告保留在独立项目 artifacts/player-canvas-performance/{before,after}。

菜单材质根层统一设置非不透明、18pt圆角和整体 masksToBounds，裁掉内部矩形内容外溢；不覆盖材质自身背景填色，保留三种背景、减少透明度回退、host身份和阴影策略。18组离屏真实根层像素检查通过（三材质、减少透明度开关、三种高度）：四角alpha为0，中心不被裁掉。脚本复制生成绑定后编译，避免与正式构建共享可变输入。

优化后的严格8组动画检查再次通过，每方向仍有3至4个位图中间态，保留反向连续、同一封面/歌词视图、分页返回、静止后无额外计时器、事件跟踪模式推进。所有检查不排序或激活窗口，不操作系统输入或接收器，不截图桌面。实际拖窗、滚动与桌面材质观感仍需用户复测。


### 0.3.33 参考 iPad 的背景缓存、歌词行高与原生播放输入

用户反馈 0.3.32 在自动歌词滚动和拖窗时都卡、播放控件无法点击，并偶发歌词闪烁。本轮参照 iPad 的低分辨率预模糊背景与双语整行高度管理，未删除 Mac 额外功能，也未修改共享音频、歌词接收/解析或手机、iPad 工作区。

背景在图片身份变化时由一个 utility 任务生成 112px ambient 和四张最大 512px cover 模糊图，多个 surface 共享缓存。窗口缩放只改变原生图层，不重新滤镜；保留原四层渐变、暗色遮罩、加载旧图和 0.6 秒淡化请求。背景 native hitTest 始终穿透。最多三张闲置缓存，活跃图另计；非方形封面按 aspectFill 短边标定。缓存专项通过共享五层、120 次缩放零新增处理、加载/取消/减少动态效果；2:1 图片与方图按同一 420pt aspectFill 显示，中心像素 RMSE 1.50，小于阈值 8。

命中区域在 position 之前限定到各角色实际范围，避免整画布 contentShape 抢占输入。三个播放控件使用原生 NSButton，保留 SF Symbols、玻璃背景、按压反馈、空格、辅助功能和启用门禁；只在隔离测试宏内用 preview 回调观察真实命令，不连接接收器。独立检查通过动画前/中/后六个局部范围；完整生产 PlayerView 的宽歌词/宽玻璃/窄封面/窄专辑四组通过 14 次根视图真实按钮命中、18 次 previous/pause/play/next 命令映射、6 次歌词页隐藏控件穿透。

歌词字号、译文比例和行距按实际 viewport 连续变化，用户 75%–200% 缩放仍生效。原文与译文由一个外层行高协调器管理，沿用原 480ms 逐词阶段和 0–1000ms 交错延迟；原生文本测量绑定文本/字体身份，防止新文本复用旧高度。Mac14、长文本、旁白及减少动态效果保留降级路径。新增专项覆盖同尺寸新文本、中英文、快速反向缩放、隐藏返回、空行、字号和辅助功能；原 Native 逐词阶段/同行位移/反向/自定义字体/长文本/240及1000ms延迟静默回归通过。

完整持久播放器八组回归再次通过，每方向保留 3–4 个实际位图几何中间态、反向位置/速度连续、同一封面和正确歌词 scroll 身份、分页返回、空闲停止计时器及事件跟踪模式推进。既有封面/专辑模式、底边歌词收展、逐词动效与用户时长、分布局控件/进度偏好、置顶、全屏、Dock/菜单入口及三种菜单材质设置保持。检查未排序/激活窗口，未发送系统输入或真实接收器命令；缓存和离屏检查不等于桌面 GPU 帧率或长期投送体验验收。

正式 0.3.33/build43 构建和严格签名通过，后台隐藏安装启动；独立读取安装版本、二进制/库和 52 个源输入校验一致。接收设置、设备身份及已有 UI 偏好保持，单一内部盘接收器进程，旧版保留在外置项目 tmp/app-before-ipad-port。报告 logs/install-0.3.33.json 与 logs/install-0.3.33-readback.json。实际自动滚动、拖窗手感和歌词闪烁是否消除仍待用户实播反馈。


### 0.3.34 缩放性能回退、歌词裁切与按钮焦点框

用户反馈加入宽窄布局元素动画前不卡，0.3.33 缩放仍卡，并有歌词模糊硬裁切、暂停蓝色边框。对照动画前 5a667f7 与冻结的 0.3.33。首次5秒采样主要空闲，不作为缩放现场；用户随后主动缩放15秒，现场栈记录 Driver.move→settle→Published.send→GraphHost.flushTransactions→TextKit 额外同步排版，保存于 logs/player-0.3.33-active-resize.sample.txt。

驱动从三个 Published 值改为完整状态写入后的一次通知。普通缩放直接使用父布局 target，不重复发布几何和 false 状态；动画开始、每帧和结束各通知一次。原临界阻尼、反向位置/速度连续、common-mode计时器保留。新增检查确认普通几何零次额外通知；完整八组 PlayerView 回归仍有3至4个实际位图几何中间态，保留分页、native scroll身份、空闲停止及eventTracking。

同步 iPad 的实际可见性、共享帧时钟、continuingLines/hasWrapped 连续换行与最终deadline清理。离屏静态更新并暂停时间线；原文/译文/行高共享非发布时钟；字形不变的宽度变化不重建动画，实际同排位移保留slide。Mac原480ms逐词阶段、190ms同行移动、4pt模糊、0–1000ms用户时差、字号/单行滚动时长及降级路径保留。高度不变只写非发布测量缓存。

歌词placement水平留24pt绘制余量后恢复原布局宽度，保留垂直裁切、contentShape、命中及窗口/分页边界。四个离屏软像素检查通过宽窗、横移中态及左右分页边界，并验证native滚动/相邻按钮命中。测试验证裁切，不把cacheDisplay当作真实GPU blur验收。按钮focusRingType=.none，空格、按压和辅助功能保留。

原生输入四布局14次根命中、18次命令映射、6次隐藏穿透及焦点框属性检查通过。歌词专项通过离屏无motionTasks、返回不补播、共享epoch、纯宽度无task、真实同排slide、同尺寸新文本、中英文、快速反向、空行、字号和辅助功能。原Native阶段、Unicode/字体/scale/长文本降级、240/1000ms时差、二次跨行不重新淡出及同deadline最终清理通过；Mac14入口未改，本轮无Mac14实机验收。

三版采用同fixture/私有FFI/-O、12条双语、artwork=nil、121步/60Hz。UI_CHECKS关闭、phaseBoundaries=0，实际有native歌词callback；预热一次本进程内存位图，测量阶段不bitmap、不显示/排序/激活窗口、不发系统输入。

首轮同模式 CPU/p95：动画前1.598s/26.59ms，0.3.33为2.364s/35.89ms，修复组合1.892s/23.88ms；跨断点分别2.288s/43.27ms、2.163s/38.10ms、2.032s/30.48ms。修复组合首轮同模式CPU较0.3.33约低20%，仍较动画前高18%，native callback仍约两倍。后续原修复控制组也明显变慢，存在平台/负载漂移，不能将单轮数字视为稳定提升或桌面FPS。

临时固定Layout实验未减少callback、CPU/p95无一致收益，未采用。报告、源码hash和失败试验说明归档于 artifacts/player-layout-comparison-0.3.34；生产不含该实验。

0.3.34/build44构建与严格签名通过，后台隐藏安装，52个源输入和安装二进制独立回读匹配。设备身份、接收设置、已有UI偏好保持，内部盘接收进程仅一个，旧版保存于 tmp/app-before-resize-recovery。报告 logs/install-0.3.34.json 与 logs/install-0.3.34-readback.json。Mac额外功能未删除，实际连续缩放、自动滚动和模糊观感仍需用户复测。


### 0.3.35 缩放歌词阅读点与窄窗约束

用户反馈横向缩窄后播放器内容被裁切，缩放期间歌词闪烁和上下跳动。本轮保留已有 Mac 功能、宽窄迁移动画、逐词换行和自定义歌词参数，不修改音频接收、手机或 iPad 工作区。

真实 PlayerView 离屏复现：原生窗口可缩到 211pt，内容仍有 260pt 下限，造成两侧各约 24.5pt 裁切。窄窗保持比例时，原生最小宽高现在取同一合法比例；普通原生拖动冻结比例，避免用逐像素舍入值重建约束。AppKit 比例模式的 contentResizeIncrements 为零是合法状态，不再据此反复解除约束。底边歌词收展仍先同步释放比例和普通下限，全屏与空闲保持释放。NSHostingView 后续媒体更新会重写最小值，因此通过公开 minSize/contentMinSize 变化合并补回丢失下限，不轮询、不写窗口几何、不降低更严格的合法下限；旧窗口与旧政策的队列均失效。

歌词行高现在依据原文与译文实际 Native 字形阶段协调。连续换行保留各字词原有消失、行高及出现时间；摘要延迟最多等待一帧。可见边缘保留一行余量，真正离屏才在动画期限后清理，防止临时滚动校正取消动画。补齐首次可见与旧静态高度已有时的最新测量恢复。

直接组件复现旧异步位置校正：当前布局误差 40pt，下一轮才归零；整机型播放器旧记录即时误差最高约 165.6pt，而下一轮已接近零。仅同步行自身 frame 通知仍漏掉 SwiftUI 随后移动普通祖先视图的阶段。现在仅持有阅读点期间观察该行普通 NSView 祖先的 frame/bounds，在同一次排版校正 clip origin；结束、取消、解绑及重挂清理。无私有类名分支、状态发布或逐帧轮询，自身滚动通知有重入保护，用户滚轮/拖动与旁白保留原门禁。

原生窗口专项通过比例下限、211pt 结束恢复、底边释放/再展开、idle/fullscreen、同一个默认 NSHostingView 三次媒体更新、合法更大下限、500ms 空闲无补偿循环和旧窗口清理。专项记录补偿路径零次 frame/content geometry 写入。逐词原有严格阶段与双语行高、两种回调顺序、75ms 旧高度、续相位、新词可见性、Unicode/字体/75%与200%、240/1000ms 和辅助功能检查通过。

默认与最大 1000/1500ms、200% 参数的真实 LyricsView 检查分别覆盖 72 个缩放布局前后点及 101 个收尾点，阅读点偏移均为 0pt；同句无多余最终回位，手动浏览、旁白、缩放中播放推进保留。未放宽新增 1pt 门槛。

完整 PlayerView + NSPanel 三布局严格回归通过：路径 760→600→599→320→280→260 并快速反向，另含强制 211pt 错误尺寸恢复、三次媒体更新和下一次 live resize。测试增加 NSHostingView.super.layout 返回后的同回合只读采样；原封面布局 214 点即时误差最大约 0.2374pt，方形分页 42 点约 0.2157pt，专辑分页 43 点为 0，全部小于 1pt。次回合、原生比例/最小值、原生滚动身份/横向零偏移、封面和控件角色范围均通过。旧失败快照保存在 before-ancestor-chain，最终报告位于 artifacts/player-rapid-resize-check/after-final；51 个实际测试 Swift 源输入已与最终源码逐项核对。

检查全程未排序或激活窗口、未发系统输入、未截桌面、未启动测试接收器或修改真实偏好。NSPanel 与纯排版检查证明本次位置和约束回归，不能等同真实 SwiftUI Window Scene、屏幕 GPU 帧率或手机实播观感验收。

0.3.35/build45 完整构建和严格签名检查通过，后台隐藏安装启动；独立读取安装版本、二进制/库和 52 个构建源输入一致。原接收设置、设备身份及 UI 偏好保留，内部盘接收器单实例；旧版保存在 tmp/app-before-resize-stability。报告 logs/install-0.3.35.json 与 logs/install-0.3.35-readback.json。


### 2026-11-23 同步 main 主线

先将已验证的 Mac 修改提交为 068619a 并推送，再合入 origin/main 的 420271a。主线有 27 个本分支尚未包含的提交，涵盖 iOS、Windows、Android 与共享接收层。本次合并目标为 feat/macos-lyrics。

冲突处理保留 Mac 现有原始字段与展示投影分离、Unicode 回退、显式空值、严格 seek 轨道校验、歌词自动/关闭选项与预览接口；合入 iOS 平台适配、Apple 同步模块与平台依赖。iOS 独立保留三种歌词模式和旧设置键迁移。Mac 的布局迁移、逐词动效、阅读锚点及窗口约束代码保持。

独立构建目录完成 macOS 发布构建与严格签名，未覆盖原版本产物或安装/重启应用。解析到 Host 状态归约的真实 packet fixture、22 个歌曲信息保护测试、Apple 同步设置持久化、50 个展示元数据案例、真实生成 Snapshot 默认值/投影与关闭选项、歌词模式迁移、默认 Swift/Rust 桥接与 128 并发系统跳转回调检查通过。Bridge 未启用网络或系统媒体发布选项。

三种完整 PlayerView 布局的严格连续缩放回归通过，包含快速反向、211pt 非法宽度恢复、媒体更新后的比例下限、原生滚动身份与即时阅读点检查；保持原有即时偏移不超过 1pt 的门槛。实际测试的 51 个 Swift 源文件哈希已与合并结果逐项核对。测试未排序/激活窗口、发送系统输入或截取桌面，也未操作正在使用的接收器。

共享元数据与歌词模式使用真实 iOS SDK 加模拟 Snapshot 做类型检查通过；本轮未构建或运行 iOS 应用，未复测 Windows/Android 设备。证据保存在项目 tmp/main-merge-20261123-bfkcqanw；原生布局与类型检查不等同设备实播或屏幕帧率验收。


### 2026-11-23 再次同步 main（3653de6）

检查 origin/main 与原始 upstream/main 后，前者有 6 个新增提交至 3653de6，后者 b43fe11 已包含在本分支中。本轮将这 6 个 main 提交合入 feat/macos-lyrics，包含 iPad 界面调整与共享音量记忆接口。

自动合并保留既有歌曲信息加固、原始字段/展示投影和 Snapshot 三个 FFI 默认值。新增共享行为主要是待连接时设置接收音量、读取当前增益与保存音量；iOS 的启动音量门禁按平台生效。去重了自动合并产生的相同 Apple 依赖表。Mac Swift 源码与此前通过三布局回归的版本相同。

独立目录完成 macOS 发布构建、重新生成 FFI 与严格签名检查。SDK 两个 receiver_volume 测试通过；Host 默认库测试 20 项通过，两个需实际 LAN/输出的 ignored 项保持跳过。真实生成 Snapshot 的默认值、关闭修正选项、显式空值与缓存检查，以及默认 Swift/Rust 桥接、设置持久化和 128 并发系统跳转回调检查通过。

本轮未开启 Bridge 网络/系统媒体发布选项，测试使用独立数据；已安装应用继续运行。未重新执行无代码变化的界面布局回归，也未运行 iPad 或其他平台设备测试。构建与原始报告保存在项目 tmp/main-refresh-20261123-3s377fb9。
