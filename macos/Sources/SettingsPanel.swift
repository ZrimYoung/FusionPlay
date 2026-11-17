import AppKit
import SwiftUI

enum ReceiverSettingsPage: String, CaseIterable, Identifiable {
    case receiver, appearance, advanced, about
    var id: Self { self }
    var title: String {
        switch self { case .receiver: return "接收"; case .appearance: return "外观"; case .advanced: return "高级"; case .about: return "关于" }
    }
    var symbol: String {
        switch self { case .receiver: return "antenna.radiowaves.left.and.right"; case .appearance: return "paintbrush"; case .advanced: return "slider.horizontal.3"; case .about: return "info.circle" }
    }
}

struct SettingsPanel: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("playerControlsAlwaysVisible") private var controlsAlwaysVisible = false
    @AppStorage("playerWindowPinned") private var pinned = false
    @AppStorage("playerShowsPinButton") private var showPinButton = false
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("playerShowsProgress") private var showProgress = true
    @AppStorage("playerLyricsDisplayMode") private var lyricsDisplayMode = "automatic"
    @AppStorage("playerProgressColorMode") private var progressColorMode = "white"
    @AppStorage("playerProgressCustomHex") private var customHex = PlayerAppearance.defaultCustomHex
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @ObservedObject var model: ReceiverModel
    @State private var selection: ReceiverSettingsPage?
    @AppStorage("settingsSidebarVisible") private var sidebarVisible = true
    @StateObject private var titlebarLayout = SettingsTitlebarLayout()
    @State private var diagnosticsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: ReceiverModel, initialPage: ReceiverSettingsPage = .receiver) {
        self.model = model; _selection = State(initialValue: initialPage)
    }
    var body: some View {
        // Keep the native List at one width and one identity. Animating a native
        // split-view insertion also animates its divider/toolbar geometry, which
        // competes with SwiftUI's transition and makes labels jump during collapse.
        HStack(spacing: 0) {
            sidebarColumn
            Group {
                switch selection ?? .receiver {
                case .receiver: receiverPage
                case .appearance: appearancePage
                case .advanced: advancedPage
                case .about: aboutPage
                }
            }.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .transaction { $0.animation = nil }
        }
        .toolbar {
            ToolbarItem(id: "fusionplay.settings.sidebar", placement: .navigation) {
                Button { sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.leading").frame(width: 18, height: 18)
                }
                .help(sidebarActionTitle)
                .accessibilityLabel(sidebarActionTitle)
                .accessibilityIdentifier("settings.sidebar.toggle")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            if sidebarVisible {
                pageTitleToolbarItem
            } else {
                ToolbarItem(id: "fusionplay.settings.pages", placement: .principal) {
                    Picker(L("设置导航"), selection: pageSelection) {
                        ForEach(ReceiverSettingsPage.allCases) { page in
                            Text(L(page.title)).tag(page)
                        }
                    }.pickerStyle(.segmented).labelsHidden()
                        .frame(width: language == "en" ? 360 : 240)
                        .accessibilityIdentifier("settings.navigation.tabs")
                }
            }
        }
        .frame(minWidth: 660, minHeight: 500)
    }
    private var pageSelection: Binding<ReceiverSettingsPage> {
        Binding(get: { selection ?? .receiver }, set: { selection = $0 })
    }
    @ToolbarContentBuilder private var pageTitleToolbarItem: some ToolbarContent {
        let title = ToolbarItem(id: "fusionplay.settings.title", placement: .navigation) {
            SettingsToolbarTitle(text: L((selection ?? .receiver).title), layout: titlebarLayout)
                .frame(width: 240, height: 20)
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            title.sharedBackgroundVisibility(.hidden)
        } else {
            title
        }
#else
        title
#endif
    }
    private var sidebarColumn: some View {
        HStack(spacing: 0) {
            List(ReceiverSettingsPage.allCases, selection: $selection) { page in
                Label(L(page.title), systemImage: page.symbol).tag(page)
            }.listStyle(.sidebar)
                // Refresh native row labels when changing language; keep the
                // list identity stable while switching navigation layouts.
                .id(language)
                .frame(width: 172).frame(maxHeight: .infinity)
                .transaction { $0.animation = nil }
            Divider().frame(width: 1)
        }.frame(width: 173, alignment: .leading)
            .frame(width: sidebarVisible ? 173 : 0, alignment: .leading)
            .clipped()
            .background { SettingsSidebarWindowBehavior(layout: titlebarLayout).allowsHitTesting(false).accessibilityHidden(true) }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: sidebarVisible)
            .allowsHitTesting(sidebarVisible).disabled(!sidebarVisible)
            .accessibilityHidden(!sidebarVisible)
            .accessibilityIdentifier("settings.sidebar.viewport")
    }
    private var sidebarActionTitle: String {
        L(sidebarVisible ? "隐藏侧栏" : "显示侧栏")
    }
    private var receiverPage: some View {
        VStack(spacing: 0) {
            Form {
                Section(L("设备与网络")) {
                    TextField(L("设备名称"), text: $model.name)
                    Picker(L("网络接口"), selection: $model.interfaceName) {
                        Text(L("自动选择局域网")).tag("")
                        ForEach(model.networks, id: \.address) { item in
                            Text("\(item.name) · \(item.address)").tag(item.name)
                        }
                        if !model.interfaceName.isEmpty && !model.networks.contains(where: { $0.name == model.interfaceName }) {
                            Text(model.interfaceName + " (" + L("不可用") + ")").tag(model.interfaceName)
                        }
                    }
                }
                Section(L("声音输出")) {
                    Picker(L("输出设备"), selection: $model.outputDevice) {
                        Text(L("跟随系统输出")).tag("")
                        ForEach(model.outputs, id: \.id) { item in Text(item.name).tag(item.id) }
                        if !model.outputDevice.isEmpty && !model.outputs.contains(where: { $0.id == model.outputDevice }) {
                            Text(L("所选设备已断开")).tag(model.outputDevice)
                        }
                    }
                }
                Section {
                    LabeledContent(L("状态"), value: L(model.phaseLabel))
                } footer: {
                    Text(L("重新连接后，可能需要在手机上重新选择此设备。全屋播放请在手机中添加 Mac。"))
                }
                if !model.error.isEmpty { Section { Text(model.error).foregroundStyle(.red).textSelection(.enabled) } }
            }.formStyle(.grouped)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(model.wantsReceiving ? L("保存并重新连接") : L("保存并启动接收")) { model.start() }
                    .buttonStyle(.borderedProminent).disabled(model.busy || !model.initialized)
                if model.wantsReceiving { Button(L("停止接收")) { model.stop() }.disabled(model.busy) }
                Spacer(minLength: 0)
            }.padding(20).background(.bar)
        }
    }
    private var appearancePage: some View {
        Form {
            Section(L("播放显示")) {
                Toggle(L("显示播放控制"), isOn: $showPlaybackControls)
                Toggle(L("显示进度与时间"), isOn: $showProgress)
                Picker(L("显示歌词"), selection: $lyricsDisplayMode) {
                    ForEach(LyricsDisplayMode.allCases, id: \.rawValue) { mode in
                        Text(L(mode.title)).tag(mode.rawValue)
                    }
                }.pickerStyle(.segmented)
                    .help(L("自动：有歌词时显示，无歌词时隐藏。歌词由手机提供。"))
                Picker(L("进度条颜色"), selection: $progressColorMode) {
                    ForEach(ProgressColorMode.allCases, id: \.rawValue) { mode in Text(L(mode.title)).tag(mode.rawValue) }
                }.pickerStyle(.segmented)
                if progressColorMode == "custom" {
                    ColorPicker(L("自定义颜色"), selection: Binding(
                        get: { Color(nsColor: PlayerAppearance.nsColor(hex: customHex)) },
                        set: { customHex = PlayerAppearance.hex($0) }), supportsOpacity: false)
                }
            }
            Section(L("迷你播放器")) {
                Picker(L("控件显示"), selection: $controlsAlwaysVisible) {
                    Text(L("悬浮显示")).tag(false)
                    Text(L("始终显示")).tag(true)
                }.pickerStyle(.segmented)
                Toggle(L("窗口置顶"), isOn: $pinned)
                Toggle(L("显示置顶按钮"), isOn: $showPinButton)
            }
            Section(L("应用入口")) {
                Toggle(L("显示 Dock 图标"), isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, visible in applyDockVisibility(visible) }
                Toggle(L("显示菜单栏图标"), isOn: $showMenuBarIcon)
                if !showDockIcon && !showMenuBarIcon {
                    Text(L("两个入口都隐藏时，再次打开应用可进入设置。")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("语言")) {
                Picker(L("界面语言"), selection: $language) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }.pickerStyle(.segmented)
            }
        }.formStyle(.grouped)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: progressColorMode)
    }
    private var advancedPage: some View {
        Form {
            Section(L("同步微调")) {
                SyncAdjustmentControl(model: model)
                Text(L("提前幅度受已接收音频限制。调整时会短暂重新同步；如出现断音，请减小幅度或恢复默认。"))
                    .font(.caption).foregroundStyle(.secondary)
                if !model.syncAdjustmentError.isEmpty { Text(model.syncAdjustmentError).font(.caption).foregroundStyle(.red) }
            }
            Section {
                DisclosureGroup(L("同步诊断"), isExpanded: $diagnosticsExpanded) {
                    LabeledContent(L("状态"), value: L(model.phaseLabel))
                    LabeledContent(L("专辑封面"), value: L(model.artworkStatus))
                    if model.snapshot?.controlsAvailable == true && model.artwork == nil {
                        Button(L("重新加载封面")) { model.reloadArtwork() }.disabled(model.artworkLoading)
                    }
                    if let state = model.snapshot {
                        LabeledContent(L("输出设备"), value: state.output.isEmpty ? L("尚未输出") : state.output)
                        LabeledContent(L("音频缓冲"), value: String(format: "%.1f ms", state.queueMs))
                        LabeledContent(L("设备输出延迟"), value: String(format: "%.1f ms", state.outputLatencyMs))
                        LabeledContent(L("调度误差"), value: String(format: "%.1f ms", state.scheduleErrorMs))
                        LabeledContent(L("欠载 / 重新同步"), value: "\(state.underruns) / \(state.resyncs)")
                    }
                    Text(L("调度误差是软件内部指标，不代表与其他音箱的实测声音偏差。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section(L("数据与日志")) {
                Button(L("打开日志")) { model.openLogs() }
                Button(L("打开数据与卸载目录")) { NSWorkspace.shared.open(model.root) }
            }
        }.formStyle(.grouped)
    }
    private var aboutPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                AboutBrandIcon().frame(width: 88, height: 88).accessibilityHidden(true)
                Text("FusionPlay").font(.system(size: 25, weight: .semibold))
                Text(L("Mac 妙播接收器")).foregroundStyle(.secondary)
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Link(L("项目主页"), destination: URL(string: "https://github.com/ZrimYoung/FusionPlay")!)
                Button(L("查看许可证")) {
                    if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(url) }
                }.buttonStyle(.link)
                Text(L("开源许可：AGPL-3.0-only")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 58).padding(.horizontal, 28)
        }
    }
}

/// Match the title to the detail column's actual animated leading edge. This
/// shared reference changes native label geometry without publishing SwiftUI
/// state on every animation frame or rebuilding the toolbar.
private final class SettingsTitlebarLayout: ObservableObject {
    weak var sidebar: NSView?
    weak var title: SettingsToolbarTitle.TitleView?
    func alignTitle() {
        guard let sidebar, let title, let window = sidebar.window, title.window === window else { return }
        title.align(to: sidebar.bounds.width + 30)
    }
}

private struct SettingsToolbarTitle: NSViewRepresentable {
    let text: String
    let layout: SettingsTitlebarLayout
    final class TitleView: NSView {
        let label = NSTextField(labelWithString: "")
        weak var titlebarLayout: SettingsTitlebarLayout?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            label.identifier = NSUserInterfaceItemIdentifier("fusionplay.settings.title.label")
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var mouseDownCanMoveWindow: Bool { true }
        override func layout() { super.layout(); titlebarLayout?.alignTitle() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); titlebarLayout?.alignTitle() }
        func align(to contentLeading: CGFloat) {
            guard window != nil else { return }
            // A collapsed sidebar must leave space for the native window and
            // sidebar controls. The navigation item's leading edge is that limit.
            let offset = max(0, contentLeading - convert(bounds, to: nil).minX)
            let size = label.intrinsicContentSize
            // Give the cell the available toolbar span, including its text
            // insets, rather than constraining it to the glyphs' intrinsic width.
            let rect = NSRect(x: offset, y: (bounds.height - size.height) / 2,
                              width: max(0, bounds.width - offset), height: size.height)
            if label.frame != rect { label.frame = rect }
        }
    }
    func makeNSView(context: Context) -> TitleView {
        let view = TitleView()
        view.titlebarLayout = layout
        layout.title = view
        return view
    }
    func updateNSView(_ view: TitleView, context: Context) {
        if view.label.stringValue != text { view.label.stringValue = text }
        layout.title = view
        layout.alignTitle()
    }
}

/// Hide only the standard title drawing, preserving the Window scene's title
/// for accessibility, the Window menu, and native window restoration.
private struct SettingsSidebarWindowBehavior: NSViewRepresentable {
    let layout: SettingsTitlebarLayout
    final class WindowView: NSView {
        weak var titlebarLayout: SettingsTitlebarLayout?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            titlebarLayout?.alignTitle()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); titlebarLayout?.alignTitle() }
        override func setBoundsSize(_ newSize: NSSize) { super.setBoundsSize(newSize); titlebarLayout?.alignTitle() }
        override func layout() { super.layout(); titlebarLayout?.alignTitle() }
    }
    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.identifier = NSUserInterfaceItemIdentifier("fusionplay.settings.sidebar.viewport")
        view.titlebarLayout = layout
        layout.sidebar = view
        return view
    }
    func updateNSView(_ view: WindowView, context: Context) {
        if let window = view.window, window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        layout.sidebar = view
        layout.alignTitle()
    }
}
