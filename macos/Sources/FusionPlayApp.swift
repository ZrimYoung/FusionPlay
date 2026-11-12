import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var showPlayer: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppBrand.applyDockIcon()
        let duplicates = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        if duplicates.count > 1 { NSApp.terminate(nil) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let showPlayer else { return true }
        showPlayer()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ReceiverModel.shared.terminate { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct FusionPlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = ReceiverModel.shared
    var body: some Scene {
        Window("FusionPlay · 正在播放", id: "player") {
            PlayerWindowContent(model: model, delegate: delegate)
        }.defaultSize(width: 760, height: 400)
          .windowStyle(.hiddenTitleBar)
          .windowResizability(.contentMinSize)
          .commands { ReceiverSettingsCommands() }
        MenuBarExtra {
            ReceiverPanel(model: model)
        } label: {
            Image(nsImage: AppBrand.menuIcon).accessibilityLabel("FusionPlay")
        }.menuBarExtraStyle(.window)
        Window("FusionPlay 设置", id: "settings") {
            SettingsPanel(model: model)
        }.defaultSize(width: 480, height: 430)
          .windowResizability(.contentSize)
    }
}

private struct ReceiverSettingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut(",", modifiers: .command)
        }
    }
}

private struct PlayerWindowContent: View {
    @ObservedObject var model: ReceiverModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        PlayerView(model: model).onAppear {
            // Keep SwiftUI responsible for recreating a closed player window.
            delegate.showPlayer = {
                openWindow(id: "player")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private struct PlayerWindowBehavior: NSViewRepresentable {
    let square: Bool
    let dimButtons: Bool
    let pinned: Bool
    let duration: Double
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = pinned ? .floating : .normal
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(kind)?.animator().alphaValue = dimButtons ? 0.22 : 1
                }
            }
            let desired = square ? NSSize(width: 1, height: 1) : .zero
            guard window.contentAspectRatio != desired else { return }
            window.contentAspectRatio = desired
            if square {
                let width = max(260, window.contentLayoutRect.width)
                window.setContentSize(NSSize(width: width, height: width))
            }
        }
    }
}

struct ReceiverPanel: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let artwork = model.artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                    }
                }.frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(model.artwork == nil ? "暂无专辑封面" : "专辑封面")
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.snapshot?.title.isEmpty == false ? model.snapshot!.title : "FusionPlay")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(model.snapshot?.artist.isEmpty == false ? model.snapshot!.artist : model.phaseLabel)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            PlaybackControls(model: model)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.system(size: 10))
                Slider(value: $model.volume, in: 0...100) { editing in model.volumeEditingChanged(editing) }
                    .controlSize(.small).accessibilityLabel("接收音量")
                    .accessibilityValue("\(Int(model.volume.rounded()))%")
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11))
            }.frame(width: 190).foregroundStyle(.secondary).disabled(!model.initialized)
            if !model.error.isEmpty {
                Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if model.controlMessage.hasPrefix("播放控制失败") {
                Text(model.controlMessage).font(.caption).foregroundStyle(.red)
            }
            Divider()
            HStack(spacing: 0) {
                action("play.rectangle", label: "正在播放") {
                    openWindow(id: "player"); NSApp.activate(ignoringOtherApps: true)
                }
                Spacer(minLength: 0)
                action("gearshape", label: "设置") {
                    openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true)
                }
                Spacer(minLength: 0)
                action("power", label: "退出 FusionPlay") { NSApp.terminate(nil) }
            }.foregroundStyle(.secondary)
        }.padding(16).frame(width: 280)
    }
    private func action(_ symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular)).frame(width: 32, height: 30)
        }.buttonStyle(MenuActionStyle()).help(label).accessibilityLabel(label)
    }
}

private struct MenuActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(enabled && (hovering || configuration.isPressed) ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? (configuration.isPressed ? 0.55 : 1) : 0.35)
            .onHover { hovering = $0 }
    }
}

struct PlaybackControls: View {
    @ObservedObject var model: ReceiverModel
    var body: some View {
        HStack(spacing: 26) {
            Spacer()
            Button { model.control(.previous) } label: { Image(systemName: "backward.end.fill") }
                .help("上一曲").accessibilityLabel("上一曲")
            Button { model.togglePlayback() } label: {
                Image(systemName: model.snapshot?.phase == .playing ? "pause.fill" : "play.fill")
                    .font(.title2).frame(width: 32, height: 32)
            }.help(model.snapshot?.phase == .playing ? "暂停" : "播放")
                .accessibilityLabel(model.snapshot?.phase == .playing ? "暂停" : "播放")
            Button { model.control(.next) } label: { Image(systemName: "forward.end.fill") }
                .help("下一曲").accessibilityLabel("下一曲")
            Spacer()
        }.buttonStyle(MenuActionStyle()).disabled(!model.canControl)
    }
}

struct PlayerView: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.colorSchemeContrast) private var colorContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pinned = false
    @State private var miniControlsHeight: CGFloat = 180
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var playing: Bool { model.snapshot?.phase == .playing }
    private var title: String {
        if let title = model.snapshot?.title, !title.isEmpty { return title }
        return model.snapshot?.controlsAvailable == true ? "手机正在投送" : "等待你的音乐"
    }
    private var artist: String {
        if let artist = model.snapshot?.artist, !artist.isEmpty { return artist }
        if model.snapshot?.controlsAvailable == true { return "" }
        return model.wantsReceiving ? "在手机妙播中选择这台 Mac" : "可在菜单栏开启接收"
    }
    private func time(_ milliseconds: UInt64?) -> String {
        guard let milliseconds else { return "–:––" }
        let seconds = milliseconds / 1000
        return String(format: "%llu:%02llu", seconds / 60, seconds % 60)
    }
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 600 && geometry.size.height >= 360 {
                expanded(size: geometry.size)
            } else {
                mini(size: geometry.size)
            }
            PlayerWindowBehavior(square: geometry.size.width < 600 || geometry.size.height < 360,
                                 dimButtons: (geometry.size.width < 600 || geometry.size.height < 360) && !hovering && !voiceOver,
                                 pinned: pinned, duration: reduceMotion ? 0 : 0.35)
                .frame(width: 0, height: 0)
        }.frame(minWidth: 260, minHeight: 260)
            .ignoresSafeArea(.container, edges: .top)
            .foregroundStyle(.white)
            .background { backdrop.ignoresSafeArea() }
            .environment(\.colorScheme, .dark)
    }
    private func expanded(size: CGSize) -> some View {
        let side = min(360, size.height - 80, size.width * 0.37)
        return HStack(alignment: .top, spacing: 28) {
            cover(side: side)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(title).font(.system(size: 25, weight: .semibold))
                        .lineLimit(2).textSelection(.enabled).help(title)
                    if !artist.isEmpty {
                        Text(artist).font(.system(size: 14)).foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2).help(artist)
                    }
                }.frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                Spacer(minLength: 18)
                if !model.error.isEmpty {
                    Label(model.error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2).help(model.error).padding(.bottom, 10)
                }
                progress
                HStack(spacing: 28) {
                    Spacer(minLength: 0)
                    transport("backward.end.fill", label: "上一曲") { model.control(.previous) }
                    Button { model.togglePlayback() } label: {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 23, weight: .semibold))
                            .offset(x: playing ? 0 : 1)
                            .frame(width: 62, height: 62)
                            .modifier(PlayerGlass())
                    }.buttonStyle(PlayerTransportStyle()).disabled(!model.canControl)
                        .opacity(model.canControl ? 1 : 0.45)
                        .help(playing ? "暂停" : "播放").accessibilityLabel(playing ? "暂停" : "播放")
                    transport("forward.end.fill", label: "下一曲") { model.control(.next) }
                    Spacer(minLength: 0)
                }.padding(.top, 16)
            }.frame(maxWidth: 440).frame(height: side)
        }.padding(.horizontal, 28)
            .frame(width: size.width, height: size.height, alignment: .center)
    }
    private func mini(size: CGSize) -> some View {
        let showControls = hovering || voiceOver
        let fadeStart = max(0, 1 - (miniControlsHeight + 24) / max(size.height, 1))
        let fadeMiddle = fadeStart + (1 - fadeStart) * 0.55
        return ZStack(alignment: .bottom) {
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "music.note").font(.system(size: 64, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            ZStack {
                if !reduceTransparency, let artwork = model.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipped().blur(radius: 24)
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: fadeStart),
                            .init(color: .black.opacity(0.45), location: fadeMiddle),
                            .init(color: .black, location: 1)
                        ], startPoint: .top, endPoint: .bottom))
                }
                LinearGradient(stops: [
                    .init(color: .clear, location: fadeStart),
                    .init(color: .black.opacity(reduceTransparency ? 0.85 : 0.35), location: fadeMiddle),
                    .init(color: .black.opacity(0.85), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }.opacity(showControls ? 1 : 0).allowsHitTesting(false).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { pinned.toggle() } label: {
                        Image(systemName: pinned ? "pin.fill" : "pin")
                            .font(.system(size: 14, weight: .medium)).frame(width: 28, height: 28)
                    }.buttonStyle(PlayerTransportStyle())
                        .help(pinned ? "取消置顶" : "置顶窗口")
                        .accessibilityLabel(pinned ? "取消置顶" : "置顶窗口")
                        .accessibilityValue(pinned ? "已开启" : "已关闭")
                }
                if !artist.isEmpty {
                    Text(artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                progress.padding(.top, 4)
                HStack {
                    Spacer(minLength: 0)
                    transport("backward.end.fill", label: "上一曲") { model.control(.previous) }
                    transport(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放") { model.togglePlayback() }
                    transport("forward.end.fill", label: "下一曲") { model.control(.next) }
                    Spacer(minLength: 0)
                }
            }.padding(16).padding(.top, 28)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: MiniControlsHeightKey.self, value: geometry.size.height)
                })
                .onPreferenceChange(MiniControlsHeightKey.self) { miniControlsHeight = $0 }
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls).accessibilityHidden(!showControls)
        }.frame(width: size.width, height: size.height).clipped()
            .contentShape(Rectangle()).onHover { hovering = $0 }
            .accessibilityLabel("迷你播放器，\(title)")
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.35), value: showControls)
    }
    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.17, green: 0.21, blue: 0.30),
                                        Color(red: 0.16, green: 0.13, blue: 0.22),
                                        Color(red: 0.08, green: 0.10, blue: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let artwork = model.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(1.15).blur(radius: 48)
                    Color.black.opacity(colorContrast == .increased ? 0.72 : 0.48)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.22)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
    }
    private func cover(side: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.06))
            if let artwork = model.artwork {
                Image(nsImage: artwork).resizable().scaledToFit()
            } else {
                Image(systemName: "music.note").font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
            .accessibilityLabel(model.artwork == nil ? "暂无专辑封面" : "专辑封面")
    }
    private var progress: some View {
        let duration = model.snapshot?.durationMs
        let position = model.snapshot?.positionMs
        let fraction = duration.flatMap { duration in
            position.map { duration > 0 ? min(Double($0) / Double(duration), 1) : 0 }
        } ?? 0
        return VStack(spacing: 7) {
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white.opacity(0.85)).frame(width: geometry.size.width * fraction)
            }.frame(height: 3).accessibilityLabel("播放进度")
                .accessibilityValue("\(time(position)) / \(time(duration))")
            HStack {
                Text(time(position)); Spacer(); Text(time(duration))
            }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
        }.help("进度随手机上报更新，暂不支持拖动")
    }
    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
        }.buttonStyle(PlayerTransportStyle()).disabled(!model.canControl)
            .opacity(model.canControl ? 0.9 : 0.3).help(label).accessibilityLabel(label)
    }
}

private struct MiniControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// Use native glass when both the SDK and OS support it; keep macOS 14 builds usable.
private struct PlayerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.25), in: Circle())
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: Circle())
            } else {
                fallback(content)
            }
#else
            fallback(content)
#endif
        }
    }
    private func fallback(_ content: Content) -> some View {
        content.background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

struct PlayerTransportStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct SettingsPanel: View {
    @ObservedObject var model: ReceiverModel
    var body: some View {
        Form {
            Section("接收设置") {
                TextField("设备名称", text: $model.name)
                Picker("网络接口", selection: $model.interfaceName) {
                    Text("自动选择局域网").tag("")
                    ForEach(model.networks, id: \.address) { item in Text("\(item.name) · \(item.address)").tag(item.name) }
                    if !model.interfaceName.isEmpty && !model.networks.contains(where: { $0.name == model.interfaceName }) {
                        Text("\(model.interfaceName)（不可用）").tag(model.interfaceName)
                    }
                }
                Picker("声音输出", selection: $model.outputDevice) {
                    Text("跟随系统输出").tag("")
                    ForEach(model.outputs, id: \.id) { item in Text(item.name).tag(item.id) }
                    if !model.outputDevice.isEmpty && !model.outputs.contains(where: { $0.id == model.outputDevice }) {
                        Text("所选设备已断开").tag(model.outputDevice)
                    }
                }
                Button(model.wantsReceiving ? "保存并重新连接" : "保存并启动接收") { model.start() }
                    .disabled(model.busy || !model.initialized)
                if model.wantsReceiving {
                    Button("停止接收") { model.stop() }.disabled(model.busy)
                }
                Text("重新连接后，可能需要在手机上重新选择此设备。全屋播放请在手机中添加 Mac。").font(.caption).foregroundStyle(.secondary)
            }
            Section("同步诊断") {
                Button("打开日志") { model.openLogs() }
                Button("打开数据与卸载目录") { NSWorkspace.shared.open(model.root) }
                LabeledContent("状态", value: model.phaseLabel)
                LabeledContent("专辑封面", value: model.artworkStatus)
                if model.snapshot?.controlsAvailable == true && model.artwork == nil {
                    Button("重新加载封面") { model.reloadArtwork() }.disabled(model.artworkLoading)
                }
                if let s = model.snapshot {
                    LabeledContent("输出设备", value: s.output.isEmpty ? "尚未输出" : s.output)
                    LabeledContent("音频缓冲", value: String(format: "%.1f ms", s.queueMs))
                    LabeledContent("设备输出延迟", value: String(format: "%.1f ms", s.outputLatencyMs))
                    LabeledContent("调度误差", value: String(format: "%.1f ms", s.scheduleErrorMs))
                    LabeledContent("欠载 / 重新同步", value: "\(s.underruns) / \(s.resyncs)")
                }
                Text("调度误差是软件内部指标，不代表与其他音箱的实测声音偏差。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.error.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.formStyle(.grouped).frame(width: 480).padding(8)
    }
}
