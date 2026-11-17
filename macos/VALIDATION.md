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
