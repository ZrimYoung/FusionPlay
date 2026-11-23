import AppKit
import SwiftUI

enum ReceiverSettingsPage: String, CaseIterable, Identifiable {
    case receiver, appearance, advanced, about
    var id: Self { self }
    var title: String {
        switch self { case .receiver: return "接收"; case .appearance: return "外观"; case .advanced: return "高级"; case .about: return "关于" }
    }
    var symbol: String {
        switch self { case .receiver: return "speaker.wave.2"; case .appearance: return "circle.lefthalf.filled"; case .advanced: return "gearshape"; case .about: return "info.circle" }
    }
}

struct SettingsPanel: View {
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @ObservedObject var model: ReceiverModel
    @State private var selection: ReceiverSettingsPage?
    @AppStorage("settingsSidebarVisible") private var sidebarVisible = true
    @StateObject private var titlebarLayout = SettingsTitlebarLayout()
    @StateObject private var navigationMotion: SettingsNavigationMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTypography) private var typography
    init(model: ReceiverModel, initialPage: ReceiverSettingsPage = .receiver) {
        self.model = model; _selection = State(initialValue: initialPage)
        let expanded = UserDefaults.standard.object(forKey: "settingsSidebarVisible") as? Bool ?? true
        _navigationMotion = StateObject(wrappedValue: SettingsNavigationMotion(expanded: expanded))
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
            }.transaction { $0.animation = nil }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay {
                    SettingsHeaderBackdrop().allowsHitTesting(false).accessibilityHidden(true)
                }
        }
        .toolbar {
            ToolbarItem(id: "fusionplay.settings.sidebar", placement: .navigation) {
                Button { sidebarVisible.toggle() } label: {
                    Image(systemName: "sidebar.leading").font(.system(size: 13)).frame(width: 18, height: 18)
                }
                .help(sidebarActionTitle)
                .accessibilityLabel(sidebarActionTitle)
                .accessibilityIdentifier("settings.sidebar.toggle")
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
            if navigationMotion.headerExpanded {
                pageTitleToolbarItem
            } else {
                pagePickerToolbarItem
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { navigationMotion.settle(expanded: sidebarVisible) }
        .onDisappear { navigationMotion.settle(expanded: sidebarVisible) }
        .onChange(of: sidebarVisible) { _, expanded in
            navigationMotion.move(to: expanded, reduceMotion: reduceMotion)
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { navigationMotion.settle(expanded: sidebarVisible) }
        }
        .frame(minWidth: 660, minHeight: 500)
    }
    private var pageSelection: Binding<ReceiverSettingsPage> {
        Binding(get: { selection ?? .receiver }, set: { selection = $0 })
    }
    @ToolbarContentBuilder private var pageTitleToolbarItem: some ToolbarContent {
        let title = ToolbarItem(id: "fusionplay.settings.title", placement: .navigation) {
            SettingsToolbarTitle(text: L((selection ?? .receiver).title),
                                 font: typography.nsFont(size: 13, weight: .semibold), layout: titlebarLayout)
                .frame(width: 240, height: max(20, typography.nsFont(size: 13, weight: .semibold).boundingRectForFont.height))
                .opacity(navigationMotion.headerOpacity)
                .background { headerLayoutObserver(expanded: true) }
                .accessibilityHidden(navigationMotion.isTransitioning)
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
    @ToolbarContentBuilder private var pagePickerToolbarItem: some ToolbarContent {
        let pages = ToolbarItem(id: "fusionplay.settings.pages", placement: .principal) {
            pageNavigationControl
                .opacity(navigationMotion.headerOpacity)
                .background { headerLayoutObserver(expanded: false) }
                .disabled(navigationMotion.isTransitioning)
                .accessibilityHidden(navigationMotion.isTransitioning)
                .accessibilityIdentifier("settings.navigation.tabs")
        }
#if compiler(>=6.2)
        if #available(macOS 26.0, *) { pages.sharedBackgroundVisibility(.hidden) }
        else { pages }
#else
        pages
#endif
    }
    @ViewBuilder private var pageNavigationControl: some View {
        let control = Picker(L("设置导航"), selection: pageSelection) {
            ForEach(ReceiverSettingsPage.allCases) { page in Text(L(page.title)).font(typography.font(size: 13)).tag(page) }
        }.pickerStyle(.segmented).labelsHidden()
            .frame(width: language == "en" ? 360 : 240)
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            // Keep the capsule inside the fading content, rather than leaving
            // an empty system toolbar background behind during replacement.
            control.padding(.horizontal, 8).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
        } else { control }
#else
        control
#endif
    }
    private func headerLayoutObserver(expanded: Bool) -> some View {
        let revision = navigationMotion.headerRevision
        return SettingsHeaderLayoutObserver(
            item: expanded ? "fusionplay.settings.title" : "fusionplay.settings.pages", revision: revision) {
                navigationMotion.headerDidLayout(expanded: expanded, revision: revision)
            }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private var sidebarColumn: some View {
        HStack(spacing: 0) {
            List(ReceiverSettingsPage.allCases, selection: $selection) { page in
                Label {
                    Text(L(page.title)).font(typography.font(size: 13))
                } icon: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 14, weight: .regular))
                        .imageScale(.medium).frame(width: 18, height: 18)
                }.tag(page)
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
                // Refresh native row labels when changing language; keep the
                // list identity stable while switching navigation layouts.
                .id(language)
                .frame(width: 172).frame(maxHeight: .infinity)
                .transaction { $0.animation = nil }
                .opacity(navigationMotion.sidebarOpacity)
            Divider().frame(width: 1)
        }.frame(width: 173, alignment: .leading)
            .frame(width: navigationMotion.layoutExpanded ? 173 : 0, alignment: .leading)
            .clipped()
            .background { SettingsSidebarWindowBehavior(layout: titlebarLayout, transitioning: navigationMotion.isTransitioning).allowsHitTesting(false).accessibilityHidden(true) }
            .allowsHitTesting(sidebarVisible && !navigationMotion.isTransitioning)
            .disabled(!sidebarVisible || navigationMotion.isTransitioning)
            .accessibilityHidden(!sidebarVisible || navigationMotion.isTransitioning)
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
    private var appearancePage: some View { AppearanceSettingsPage(onTitleCorrectionChanged: model.refreshDisplayPresentation) }
    private var advancedPage: some View { AdvancedSettingsPage(model: model) }
    private var aboutPage: some View {
        ScrollView {
            VStack(spacing: 14) {
                AboutBrandIcon().frame(width: 88, height: 88).accessibilityHidden(true)
                Text("FusionPlay").font(typography.font(size: 25, weight: .semibold))
                Text(L("Mac 妙播接收器")).foregroundStyle(.secondary)
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    .font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.secondary)
                Link(L("项目主页"), destination: URL(string: "https://github.com/ZrimYoung/FusionPlay")!)
                Button(L("查看许可证")) {
                    if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) { NSWorkspace.shared.open(url) }
                }.buttonStyle(.link)
                Text(L("开源许可：AGPL-3.0-only")).font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.secondary)
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
    let font: NSFont
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
        if view.label.font != font { view.label.font = font }
        layout.title = view
        layout.alignTitle()
    }
}

/// Hide only the standard title drawing, preserving the Window scene's title
/// for accessibility, the Window menu, and native window restoration.
private struct SettingsSidebarWindowBehavior: NSViewRepresentable {
    let layout: SettingsTitlebarLayout
    let transitioning: Bool
    final class WindowView: NSView {
        weak var titlebarLayout: SettingsTitlebarLayout?
        private let material = NSVisualEffectView()
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            material.material = .sidebar
            material.blendingMode = .behindWindow
            material.state = .followsWindowActiveState
            addSubview(material)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        private func updateMaterial() {
            guard let window else { return }
            let chrome = max(0, window.frame.height - window.contentLayoutRect.height)
            let frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + chrome)
            if material.frame != frame { material.frame = frame }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                if !window.styleMask.contains(.fullSizeContentView) {
                    window.styleMask.insert(.fullSizeContentView)
                }
            }
            updateMaterial()
            titlebarLayout?.alignTitle()
        }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateMaterial(); titlebarLayout?.alignTitle() }
        override func setBoundsSize(_ newSize: NSSize) { super.setBoundsSize(newSize); updateMaterial(); titlebarLayout?.alignTitle() }
        override func layout() { super.layout(); updateMaterial(); titlebarLayout?.alignTitle() }
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
        view.setAccessibilityValue(transitioning ? "transitioning" : "settled")
        layout.alignTitle()
    }
}

/// Fade in only after the replacement native toolbar item has real geometry.
private struct SettingsHeaderLayoutObserver: NSViewRepresentable {
    let item: String
    let revision: Int
    let ready: () -> Void
    final class ProbeView: NSView {
        var item = ""
        var revision = -1
        var ready: (() -> Void)?
        private var delivered = -1
        private var scheduled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            guard window != nil, delivered != revision, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard let window = self.window,
                      let view = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == self.item })?.view,
                      view.window === window, view.bounds.width > 0, view.bounds.height > 0 else { return }
                // The Window scene can set the standard title after the
                // content first attaches. Suppress it at toolbar readiness too.
                if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
                self.delivered = self.revision
                self.ready?()
            }
        }
    }
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {
        view.item = item; view.revision = revision; view.ready = ready
        view.schedule()
    }
}
