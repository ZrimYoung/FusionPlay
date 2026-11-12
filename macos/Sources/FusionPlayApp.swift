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
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = ReceiverModel.shared
    var body: some Scene {
        Window(L("FusionPlay · 正在播放"), id: "player") {
            PlayerWindowContent(model: model, delegate: delegate)
                .environment(\.locale, Locale(identifier: language))
        }.defaultSize(width: 760, height: 400)
          .windowStyle(.hiddenTitleBar)
          .windowResizability(.contentMinSize)
          .commands { ReceiverSettingsCommands() }
        MenuBarExtra {
            ReceiverPanel(model: model)
                .environment(\.locale, Locale(identifier: language))
        } label: {
            Image(nsImage: AppBrand.menuIcon).accessibilityLabel("FusionPlay")
        }.menuBarExtraStyle(.window)
        Window(L("FusionPlay 设置"), id: "settings") {
            SettingsPanel(model: model)
                .environment(\.locale, Locale(identifier: language))
        }.defaultSize(width: 480, height: 430)
          .windowResizability(.contentSize)
    }
}

private struct ReceiverSettingsCommands: Commands {
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L("设置…")) {
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
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @ObservedObject var model: ReceiverModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                Group {
                    if let artwork = model.artwork {
                        ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                            .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                    }
                }.frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(model.artwork == nil ? L("暂无专辑封面") : L("专辑封面"))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.snapshot?.title.isEmpty == false ? model.snapshot!.title : "FusionPlay")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text(model.snapshot?.artist.isEmpty == false ? model.snapshot!.artist : L(model.phaseLabel))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            PlaybackControls(model: model)
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").font(.system(size: 10))
                Slider(value: $model.volume, in: 0...100) { editing in model.volumeEditingChanged(editing) }
                    .controlSize(.small).accessibilityLabel(L("接收音量"))
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
                action("play.rectangle", label: L("正在播放")) {
                    openWindow(id: "player"); NSApp.activate(ignoringOtherApps: true)
                }
                Spacer(minLength: 0)
                action("gearshape", label: L("设置")) {
                    openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true)
                }
                Spacer(minLength: 0)
                action("power", label: L("退出 FusionPlay")) { NSApp.terminate(nil) }
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
                .help(L("上一曲")).accessibilityLabel(L("上一曲"))
            Button { model.togglePlayback() } label: {
                Image(systemName: model.snapshot?.phase == .playing ? "pause.fill" : "play.fill")
                    .font(.title2).frame(width: 32, height: 32)
            }.help(model.snapshot?.phase == .playing ? L("暂停") : L("播放"))
                .accessibilityLabel(model.snapshot?.phase == .playing ? L("暂停") : L("播放"))
            Button { model.control(.next) } label: { Image(systemName: "forward.end.fill") }
                .help(L("下一曲")).accessibilityLabel(L("下一曲"))
            Spacer()
        }.buttonStyle(MenuActionStyle()).disabled(!model.canControl)
    }
}

struct PlayerView: View {
    @AppStorage("playerControlsAlwaysVisible") private var controlsAlwaysVisible = false
    @AppStorage("playerWindowPinned") private var pinned = false
    @AppStorage("playerShowsPinButton") private var showPinButton = false
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @ObservedObject var model: ReceiverModel
    @Environment(\.colorSchemeContrast) private var colorContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pointerInside = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var showMiniControls: Bool { hovering || controlsAlwaysVisible || voiceOver }
    private var playing: Bool { model.snapshot?.phase == .playing }
    private var title: String {
        if let title = model.snapshot?.title, !title.isEmpty { return title }
        return model.snapshot?.controlsAvailable == true ? L("手机正在投送") : L("等待你的音乐")
    }
    private var artist: String {
        if let artist = model.snapshot?.artist, !artist.isEmpty { return artist }
        if model.snapshot?.controlsAvailable == true { return "" }
        return model.wantsReceiving ? L("在手机妙播中选择这台 Mac") : L("可在菜单栏开启接收")
    }
    private var album: String {
        model.snapshot?.album.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var subtitle: String {
        [artist, album].filter { !$0.isEmpty }.joined(separator: " - ")
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
                                 dimButtons: (geometry.size.width < 600 || geometry.size.height < 360) && !showMiniControls,
                                 pinned: pinned, duration: reduceMotion ? 0 : (showMiniControls ? 0.25 : 0.65))
                .frame(width: 0, height: 0)
        }.frame(minWidth: 260, minHeight: 260)
            .ignoresSafeArea(.container, edges: .top)
            .foregroundStyle(.white)
            .background { backdrop.ignoresSafeArea() }
            .environment(\.colorScheme, .dark)
            .animation(.easeInOut(duration: reduceMotion ? 0 : 0.35), value: showPlaybackControls)
    }
    private func expanded(size: CGSize) -> some View {
        let side = min(360, size.height - 80, size.width * 0.37)
        return HStack(alignment: .top, spacing: 28) {
            cover(side: side)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(title).font(.system(size: 28, weight: .semibold))
                        .lineLimit(2).textSelection(.enabled).help(title)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 14)).foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1).help(subtitle)
                    }
                }.frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                Spacer(minLength: 18)
                if !model.error.isEmpty {
                    Label(model.error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2).help(model.error).padding(.bottom, 10)
                }
                progress
                if showPlaybackControls {
                    HStack(spacing: 28) {
                        Spacer(minLength: 0)
                        transport("backward.end.fill", label: L("上一曲")) { model.control(.previous) }
                        Button { model.togglePlayback() } label: {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 23, weight: .semibold))
                                .offset(x: playing ? 0 : 1)
                                .frame(width: 62, height: 62)
                                .modifier(PlayerGlass())
                        }.buttonStyle(PlayerTransportStyle()).disabled(!model.canControl)
                            .opacity(model.canControl ? 1 : 0.45)
                            .help(playing ? L("暂停") : L("播放")).accessibilityLabel(playing ? L("暂停") : L("播放"))
                        transport("forward.end.fill", label: L("下一曲")) { model.control(.next) }
                        Spacer(minLength: 0)
                    }.padding(.top, 6)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }.frame(maxWidth: 440).frame(height: side)
        }.padding(.horizontal, 28)
            .frame(width: size.width, height: size.height, alignment: .center)
    }
    private func mini(size: CGSize) -> some View {
        let showControls = showMiniControls
        return ZStack(alignment: .bottom) {
            if let artwork = model.artwork {
                ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: .fill)
                    .frame(width: size.width, height: size.height).clipped()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "music.note").font(.system(size: 64, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 19, weight: .semibold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).help(subtitle)
                }
                VStack(spacing: 2) {
                    progress.padding(.top, 4)
                    if showPlaybackControls {
                        HStack {
                            Spacer(minLength: 0)
                            transport("backward.end.fill", label: L("上一曲")) { model.control(.previous) }
                            transport(playing ? "pause.fill" : "play.fill", label: playing ? L("暂停") : L("播放")) { model.togglePlayback() }
                            transport("forward.end.fill", label: L("下一曲")) { model.control(.next) }
                            Spacer(minLength: 0)
                        }.transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }.padding(16)
                .background {
                    GeometryReader { geometry in
                        miniBackdrop(size: size, controlsHeight: geometry.size.height)
                            .frame(width: size.width, height: size.height)
                            .offset(y: geometry.size.height - size.height)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
                .opacity(showControls ? 1 : 0)
                .allowsHitTesting(showControls).accessibilityHidden(!showControls)
        }.frame(width: size.width, height: size.height).clipped()
            .overlay(alignment: .topTrailing) {
                if showPinButton {
                Button { pinned.toggle() } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .regular))
                        .rotationEffect(.degrees(35))
                        .foregroundStyle(.white.opacity(pinned ? 1 : 0.65))
                        .frame(width: 28, height: 28)
                }.buttonStyle(PlayerTransportStyle())
                    .help(pinned ? L("取消置顶") : L("置顶窗口"))
                    .accessibilityLabel(pinned ? L("取消置顶") : L("置顶窗口"))
                    .accessibilityValue(pinned ? L("已开启") : L("已关闭"))
                    .padding(12)
                    .opacity(showControls ? 1 : 0)
                    .allowsHitTesting(showControls).accessibilityHidden(!showControls)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                pointerInside = inside
                if inside { hovering = true }
            }
            .task(id: pointerInside) {
                guard !pointerInside else { return }
                do { try await Task.sleep(nanoseconds: 400_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                hovering = false
            }
            .onDisappear { pointerInside = false; hovering = false }
            .accessibilityLabel(L("迷你播放器") + ", " + title)
            .animation(.easeInOut(duration: reduceMotion ? 0 : (showControls ? 0.25 : 0.65)), value: showControls)
    }
    private func miniBackdrop(size: CGSize, controlsHeight: CGFloat) -> some View {
        // The background uses the same container geometry as the controls.
        // Its full-cover image is bottom-aligned to preserve artwork coordinates.
        let backdropHeight = min(size.height, controlsHeight * 1.35)
        let fadeStart = max(0, 1 - backdropHeight / max(size.height, 1))
        let fadeMiddle = fadeStart + (1 - fadeStart) * 0.55
        return ZStack {
            if !reduceTransparency, let artwork = model.artwork {
                // Blend successive blur radii over adjacent bands. Below each band
                // its layer is opaque, so sharp artwork cannot leak through the controls.
                ForEach(0..<4) { step in
                    let radii: [CGFloat] = [6, 14, 26, 40]
                    let start = fadeStart + (1 - fadeStart) * CGFloat(step) / 4
                    let end = fadeStart + (1 - fadeStart) * CGFloat(step + 1) / 4
                    ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped().blur(radius: radii[step], opaque: true)
                        .mask(LinearGradient(stops: [
                            .init(color: .clear, location: start),
                            .init(color: .black, location: end)
                        ], startPoint: .top, endPoint: .bottom))
                }
            }
            LinearGradient(stops: [
                .init(color: .clear, location: fadeStart),
                .init(color: .black.opacity(reduceTransparency ? 0.85 : 0.20), location: fadeMiddle),
                .init(color: .black.opacity(0.65), location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }.frame(width: size.width, height: size.height).clipped()
    }
    private var backdrop: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.17, green: 0.21, blue: 0.30),
                                        Color(red: 0.16, green: 0.13, blue: 0.22),
                                        Color(red: 0.08, green: 0.10, blue: 0.16)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let artwork = model.artwork {
                    ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: .fill)
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
                ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: .fit)
            } else {
                Image(systemName: "music.note").font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
            .accessibilityLabel(model.artwork == nil ? L("暂无专辑封面") : L("专辑封面"))
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
            }.frame(height: 3).accessibilityLabel(L("播放进度"))
                .accessibilityValue("\(time(position)) / \(time(duration))")
            HStack {
                Text(time(position)); Spacer(); Text(time(duration))
            }.font(.system(size: 10).monospacedDigit()).foregroundStyle(.white.opacity(0.55))
        }.help(L("进度随手机上报更新，暂不支持拖动"))
    }
    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
        }.buttonStyle(PlayerTransportStyle()).disabled(!model.canControl)
            .opacity(model.canControl ? 0.9 : 0.3).help(label).accessibilityLabel(label)
    }
}

private struct ArtworkSurface: View {
    let artwork: NSImage
    let loading: Bool
    let mode: ContentMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: mode)
                .id(ObjectIdentifier(artwork)).transition(.opacity)
        }
        .blur(radius: loading ? 10 : 0)
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.35), value: loading)
        .animation(.easeInOut(duration: reduceMotion ? 0 : 0.35), value: ObjectIdentifier(artwork))
    }
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
    @AppStorage("playerControlsAlwaysVisible") private var controlsAlwaysVisible = false
    @AppStorage("playerWindowPinned") private var pinned = false
    @AppStorage("playerShowsPinButton") private var showPinButton = false
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @State private var diagnosticsExpanded = false
    @ObservedObject var model: ReceiverModel
    var body: some View {
        TabView {
            Form {
            Section(L("接收设置")) {
                TextField(L("设备名称"), text: $model.name)
                Picker(L("网络接口"), selection: $model.interfaceName) {
                    Text(L("自动选择局域网")).tag("")
                    ForEach(model.networks, id: \.address) { item in Text("\(item.name) · \(item.address)").tag(item.name) }
                    if !model.interfaceName.isEmpty && !model.networks.contains(where: { $0.name == model.interfaceName }) {
                        Text(model.interfaceName + " (" + L("不可用") + ")").tag(model.interfaceName)
                    }
                }
                Picker(L("声音输出"), selection: $model.outputDevice) {
                    Text(L("跟随系统输出")).tag("")
                    ForEach(model.outputs, id: \.id) { item in Text(item.name).tag(item.id) }
                    if !model.outputDevice.isEmpty && !model.outputs.contains(where: { $0.id == model.outputDevice }) {
                        Text(L("所选设备已断开")).tag(model.outputDevice)
                    }
                }
                Button(model.wantsReceiving ? L("保存并重新连接") : L("保存并启动接收")) { model.start() }
                    .disabled(model.busy || !model.initialized)
                if model.wantsReceiving {
                    Button(L("停止接收")) { model.stop() }.disabled(model.busy)
                }
                Text(L("重新连接后，可能需要在手机上重新选择此设备。全屋播放请在手机中添加 Mac。")).font(.caption).foregroundStyle(.secondary)
            }
                if !model.error.isEmpty {
                    Text(model.error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }.formStyle(.grouped).tabItem { Label(L("接收"), systemImage: "antenna.radiowaves.left.and.right") }
            Form {
                Section(L("播放窗口")) {
                    Toggle(L("控件常驻"), isOn: $controlsAlwaysVisible)
                    Text(L("鼠标移出后仍显示歌曲信息、进度和已开启的控件。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("显示播放控制"), isOn: $showPlaybackControls)
                    Text(L("显示上一首、播放/暂停和下一首按钮。")).font(.caption).foregroundStyle(.secondary)
                }
                Section(L("窗口")) {
                    Toggle(L("窗口置顶"), isOn: $pinned)
                    Toggle(L("显示置顶按钮"), isOn: $showPinButton)
                }
                Section(L("语言")) {
                    Picker(L("界面语言"), selection: $language) {
                        Text(L("简体中文")).tag("zh-Hans")
                        Text("English").tag("en")
                    }
                }
            }.formStyle(.grouped).tabItem { Label(L("外观"), systemImage: "paintbrush") }
            Form {
                Section(L("同步微调")) {
                    SyncAdjustmentControl(model: model)
                    Text(L("提前幅度受已接收音频限制。调整时会短暂重新同步；如出现断音，请减小幅度或恢复默认。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.syncAdjustmentError.isEmpty {
                        Text(model.syncAdjustmentError).font(.caption).foregroundStyle(.red)
                    }
                }
                Section {
                    DisclosureGroup(L("同步诊断"), isExpanded: $diagnosticsExpanded) {
                LabeledContent(L("状态"), value: L(model.phaseLabel))
                LabeledContent(L("专辑封面"), value: L(model.artworkStatus))
                if model.snapshot?.controlsAvailable == true && model.artwork == nil {
                    Button(L("重新加载封面")) { model.reloadArtwork() }.disabled(model.artworkLoading)
                }
                if let s = model.snapshot {
                    LabeledContent(L("输出设备"), value: s.output.isEmpty ? L("尚未输出") : s.output)
                    LabeledContent(L("音频缓冲"), value: String(format: "%.1f ms", s.queueMs))
                    LabeledContent(L("设备输出延迟"), value: String(format: "%.1f ms", s.outputLatencyMs))
                    LabeledContent(L("调度误差"), value: String(format: "%.1f ms", s.scheduleErrorMs))
                    LabeledContent(L("欠载 / 重新同步"), value: "\(s.underruns) / \(s.resyncs)")
                }
                Text(L("调度误差是软件内部指标，不代表与其他音箱的实测声音偏差。")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section(L("数据与日志")) {
                    Button(L("打开日志")) { model.openLogs() }
                    Button(L("打开数据与卸载目录")) { NSWorkspace.shared.open(model.root) }
                }
            }.formStyle(.grouped).tabItem { Label(L("高级"), systemImage: "slider.horizontal.3") }
            VStack(spacing: 14) {
                AboutBrandIcon().frame(width: 80, height: 80).accessibilityHidden(true)
                Text("FusionPlay").font(.title2.bold())
                Text(L("Mac 妙播接收器")).foregroundStyle(.secondary)
                Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                Link(L("项目主页"), destination: URL(string: "https://github.com/ZrimYoung/FusionPlay")!)
                Text(L("开源许可：AGPL-3.0-only")).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem { Label(L("关于"), systemImage: "info.circle") }
        }.padding(12).frame(width: 560, height: 540)
    }
}


private struct SyncAdjustmentControl: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @State private var input = "0"
    @State private var invalidInput = false
    @FocusState private var editingValue: Bool
    private var unavailable: Bool { !model.initialized || model.syncAdjustmentBusy }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(L("播放时间偏移"))
                Spacer()
                TextField("", text: $input, prompt: Text("0"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .monospacedDigit().frame(width: 76)
                    .focused($editingValue).onSubmit { commitInput() }
                    .accessibilityLabel(L("播放时间偏移"))
                    .disabled(unavailable)
                Text("ms").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button { adjust(by: -10) } label: {
                    Image(systemName: "minus").frame(width: 24, height: 24)
                }.disabled(unavailable || model.syncAdjustment <= -200)
                    .help(L("提前 10 ms")).accessibilityLabel(L("提前 10 ms"))
                Slider(value: $model.syncAdjustment, in: -200...200) { editing in
                    if !editing {
                        model.syncAdjustment = model.syncAdjustment.rounded()
                        refreshInput()
                        model.saveSyncAdjustment()
                    }
                }.labelsHidden().frame(maxWidth: .infinity)
                    .accessibilityLabel(L("播放时间偏移")).disabled(unavailable)
                Button { adjust(by: 10) } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }.disabled(unavailable || model.syncAdjustment >= 200)
                    .help(L("延后 10 ms")).accessibilityLabel(L("延后 10 ms"))
            }.buttonStyle(.borderless)
            HStack {
                Text(L("提前")).font(.caption)
                Spacer()
                Button(L("恢复默认")) { apply(0) }
                    .disabled(unavailable || model.syncAdjustment == 0)
                Spacer()
                Text(L("延后")).font(.caption)
            }
            Text(L("负值提前，正值延后。输入后回车确认；加减按钮每次调整 10 ms。"))
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if invalidInput {
                Text(L("请输入 −200 到 200 之间的整数。"))
                    .font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(maxWidth: .infinity)
            .onAppear { refreshInput() }
            .onChange(of: model.syncAdjustment) { _, _ in if !editingValue { refreshInput() } }
            .onChange(of: editingValue) { _, focused in if !focused { commitInput() } }
    }
    private func refreshInput() {
        input = String(Int(model.syncAdjustment.rounded())); invalidInput = false
    }
    private func commitInput() {
        guard !unavailable else { return }
        guard let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
              (-200...200).contains(value) else { invalidInput = true; return }
        apply(value)
    }
    private func adjust(by step: Int) {
        apply(min(200, max(-200, Int(model.syncAdjustment.rounded()) + step)))
    }
    private func apply(_ value: Int) {
        guard !unavailable else { return }
        let changed = model.syncAdjustment != Double(value)
        model.syncAdjustment = Double(value)
        refreshInput(); editingValue = false
        if changed { model.saveSyncAdjustment() }
    }
}
