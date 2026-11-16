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
    @AppStorage("playerProgressColorMode") private var progressColorMode = "white"
    @AppStorage("playerProgressCustomHex") private var customHex = PlayerAppearance.defaultCustomHex
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @ObservedObject var model: ReceiverModel
    @State private var selection: ReceiverSettingsPage?
    @State private var diagnosticsExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(model: ReceiverModel, initialPage: ReceiverSettingsPage = .receiver) {
        self.model = model; _selection = State(initialValue: initialPage)
    }
    var body: some View {
        NavigationSplitView {
            List(ReceiverSettingsPage.allCases, selection: $selection) { page in
                Label(L(page.title), systemImage: page.symbol).tag(page)
            }.listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 150, ideal: 172, max: 210)
                .navigationTitle("FusionPlay")
        } detail: {
            Group {
                switch selection ?? .receiver {
                case .receiver: receiverPage
                case .appearance: appearancePage
                case .advanced: advancedPage
                case .about: aboutPage
                }
            }.frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(L((selection ?? .receiver).title))
        }.navigationSplitViewStyle(.balanced)
            .frame(minWidth: 660, minHeight: 500)
    }
    private var receiverPage: some View {
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
                HStack {
                    Button(model.wantsReceiving ? L("保存并重新连接") : L("保存并启动接收")) { model.start() }
                        .buttonStyle(.borderedProminent).disabled(model.busy || !model.initialized)
                    if model.wantsReceiving { Button(L("停止接收")) { model.stop() }.disabled(model.busy) }
                }
                LabeledContent(L("状态"), value: L(model.phaseLabel))
            } footer: {
                Text(L("重新连接后，可能需要在手机上重新选择此设备。全屋播放请在手机中添加 Mac。"))
            }
            if !model.error.isEmpty { Section { Text(model.error).foregroundStyle(.red).textSelection(.enabled) } }
        }.formStyle(.grouped)
    }
    private var appearancePage: some View {
        Form {
            Section(L("播放显示")) {
                Toggle(L("显示播放控制"), isOn: $showPlaybackControls)
                Toggle(L("显示进度与时间"), isOn: $showProgress)
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
