import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var showPlayer: (() -> Void)?
    private var menuPanelController: MenuPanelController?

    func configureMenuPanel(model: ReceiverModel, openWindow: @escaping (String) -> Void) {
        showPlayer = {
            let defaults = UserDefaults.standard
            let dockVisible = defaults.object(forKey: "showDockIcon") as? Bool ?? true
            let menuVisible = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
            openWindow(!dockVisible && !menuVisible ? "settings" : "player")
        }
        if let menuPanelController {
            menuPanelController.setOpenWindowAction(openWindow)
            menuPanelController.syncPreferences()
        } else {
            menuPanelController = MenuPanelController(model: model, openWindow: openWindow)
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        menuPanelController?.invalidate()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        applyDockVisibility(UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true)
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

@MainActor
func applyDockVisibility(_ visible: Bool) {
    let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
    guard NSApp.activationPolicy() != policy else { return }
    NSApp.setActivationPolicy(policy)
    if visible { AppBrand.applyDockIcon() }
}

#if !FUSIONPLAY_UI_CHECKS
@main
#endif
struct FusionPlayApp: App {
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = ReceiverModel.shared
    init() { LyricsDisplayMode.migrateLegacyPreference() }
    var body: some Scene {
        Window(L("FusionPlay · 正在播放"), id: "player") {
            PlayerWindowContent(model: model, delegate: delegate)
                .appTypography()
                .environment(\.locale, Locale(identifier: language))
        }.defaultSize(width: 760, height: 400)
          .windowStyle(.hiddenTitleBar)
          .windowResizability(.contentMinSize)
          .commands {
              ReceiverSettingsCommands()
              PlayerFullScreenCommands()
          }
        Window(L("FusionPlay 设置"), id: "settings") {
            SettingsWindowContent(model: model, delegate: delegate)
                .appTypography()
                .environment(\.locale, Locale(identifier: language))
        }.defaultSize(width: 820, height: 620)
          .windowResizability(.contentMinSize)
          .windowToolbarStyle(.unified(showsTitle: false))
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
        PlayerView(model: model).focusedSceneValue(\.playerSupportsFullScreen, true).onAppear {
            delegate.configureMenuPanel(model: model) { id in
                openWindow(id: id)
                NSApp.activate(ignoringOtherApps: true)
            }
            // A cold launch must also offer a way back when both entry icons are hidden.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: "showDockIcon") as? Bool == false,
               defaults.object(forKey: "showMenuBarIcon") as? Bool == false {
                openWindow(id: "settings")
            }
        }
    }
}

/// A restored settings-only session must also restore the status item.
private struct SettingsWindowContent: View {
    @ObservedObject var model: ReceiverModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        SettingsPanel(model: model).onAppear {
            delegate.configureMenuPanel(model: model) { id in
                openWindow(id: id)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

struct ReceiverPanel: View {
    @Environment(\.appTypography) private var typography
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @State private var volumeExpanded = false
    @State private var confirmQuit = false
    @State private var menuInfoHeight: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ReceiverModel
    var onOpenWindow: ((String) -> Void)? = nil
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: openMiniPlayer) {
                    Group {
                        if let artwork = model.artwork {
                            ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                                .overlay(Image(systemName: "music.note").font(.system(size: 13)).foregroundStyle(.secondary))
                        }
                    }.frame(width: min(96, max(72, menuInfoHeight)), height: min(96, max(72, menuInfoHeight))).clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).help(L("打开迷你播放器"))
                    .accessibilityLabel(L("打开迷你播放器"))
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: openMiniPlayer) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayMetadata.title.isEmpty ? "FusionPlay" : displayMetadata.title)
                                .font(typography.font(size: 13, weight: .semibold)).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(menuSubtitle)
                                .font(typography.font(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L("打开迷你播放器"))
                    PlaybackControls(model: model)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .background { GeometryReader { proxy in Color.clear.preference(key: MenuInfoHeight.self, value: proxy.size.height) } }
            }.onPreferenceChange(MenuInfoHeight.self) { height in
                let height = min(96, max(72, height))
                if abs(menuInfoHeight - height) > 0.5 { menuInfoHeight = height }
            }
            PlaybackProgressView(model: model, showsTime: false, menu: true)
            if !model.seekMessage.isEmpty {
                Text(L(model.seekMessage)).font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.secondary)
            }
            if !model.error.isEmpty {
                Text(model.error).font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.red).textSelection(.enabled)
            } else if model.controlMessage.hasPrefix("播放控制失败") {
                Text(model.controlMessage).font(typography.font(size: NSFont.preferredFont(forTextStyle: .caption1).pointSize)).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                action("gearshape", label: L("设置")) {
                    openAppWindow("settings")
                }
                HStack(spacing: 8) {
                    Button { volumeExpanded.toggle() } label: {
                        Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                            .font(.system(size: 14)).frame(width: 28, height: 26)
                    }.buttonStyle(MenuActionStyle())
                        .help(volumeExpanded ? L("收起音量") : L("展开音量"))
                        .accessibilityLabel(L("接收音量"))
                        .accessibilityValue(volumeExpanded ? L("已开启") : L("已关闭"))
                    MenuVolumeBar(model: model)
                        .frame(width: 104)
                        .frame(width: volumeExpanded ? 104 : 0, alignment: .leading)
                        .clipped()
                        .opacity(volumeExpanded ? 1 : 0)
                        .allowsHitTesting(volumeExpanded)
                        .accessibilityHidden(!volumeExpanded)
                }
                Spacer(minLength: 0)
                action("power", label: L("退出 FusionPlay")) { confirmQuit = true }
            }.foregroundStyle(.secondary)
                .animation(.easeInOut(duration: reduceMotion ? 0 : 0.25), value: volumeExpanded)
        }.padding(16).frame(width: 280)
            .alert(L("退出 FusionPlay？"), isPresented: $confirmQuit) {
                Button(L("取消"), role: .cancel) {}
                Button(L("退出"), role: .destructive) { NSApp.terminate(nil) }
            } message: {
                Text(L("退出后将停止接收音乐。"))
            }
    }
    private var displayMetadata: DisplayMetadata {
        if correctLyricTitles { return model.correctedDisplayMetadata }
        return DisplayMetadata(title: model.snapshot?.title ?? "", artist: model.snapshot?.artist ?? "", album: model.snapshot?.album ?? "")
    }
    private var menuSubtitle: String {
        let values = [displayMetadata.artist, displayMetadata.album].filter { !$0.isEmpty }
        return values.isEmpty ? L(model.phaseLabel) : values.joined(separator: " - ")
    }
    private func openMiniPlayer() {
        model.miniPlayerRequest &+= 1
        openAppWindow("player")
    }
    private func openAppWindow(_ id: String) {
        if let onOpenWindow { onOpenWindow(id) }
        else {
            openWindow(id: id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    private func action(_ symbol: String, label: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular)).frame(width: 28, height: 26)
        }.buttonStyle(MenuActionStyle()).help(label).accessibilityLabel(label)
    }
}

private struct MenuInfoHeight: PreferenceKey {
    static var defaultValue: CGFloat = 72
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct MenuVolumeBar: View {
    @ObservedObject var model: ReceiverModel
    @State private var dragging = false
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Color.primary.opacity(0.45))
                    .frame(width: geometry.size.width * min(1, max(0, model.volume / 100)))
            }.frame(height: 3).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging { dragging = true; model.volumeEditingChanged(true) }
                        setVolume(value.location.x, width: geometry.size.width)
                    }
                    .onEnded { value in
                        setVolume(value.location.x, width: geometry.size.width)
                        dragging = false; model.volumeEditingChanged(false)
                    })
        }.frame(height: 18).allowsHitTesting(model.initialized)
            .opacity(model.initialized ? 1 : 0.4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L("接收音量"))
            .accessibilityValue("\(Int(model.volume.rounded()))%")
            .accessibilityAdjustableAction { direction in
                guard model.initialized else { return }
                let step: Double
                switch direction { case .increment: step = 5; case .decrement: step = -5; @unknown default: return }
                model.volumeEditingChanged(true)
                model.volume = min(100, max(0, model.volume + step))
                model.volumeEditingChanged(false)
            }
            .help(L("接收音量") + " \(Int(model.volume.rounded()))%")
            .onDisappear {
                if dragging { dragging = false; model.volumeEditingChanged(false) }
            }
    }
    private func setVolume(_ x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        model.volume = min(100, max(0, Double(x / width) * 100))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: ReceiverModel
    var body: some View {
        HStack(spacing: 12) {
            Button { model.control(.previous) } label: { Image(systemName: "backward.end.fill").font(.system(size: 13)).frame(width: 26, height: 26) }
                .help(L("上一曲")).accessibilityLabel(L("上一曲"))
            Button { model.togglePlayback() } label: {
                Image(systemName: model.snapshot?.phase == .playing ? "pause.fill" : "play.fill")
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.snapshot?.phase == .playing)
                    .font(.system(size: 16)).frame(width: 28, height: 26)
            }.help(model.snapshot?.phase == .playing ? L("暂停") : L("播放"))
                .accessibilityLabel(model.snapshot?.phase == .playing ? L("暂停") : L("播放"))
            Button { model.control(.next) } label: { Image(systemName: "forward.end.fill").font(.system(size: 13)).frame(width: 26, height: 26) }
                .help(L("下一曲")).accessibilityLabel(L("下一曲"))
        }.buttonStyle(MenuActionStyle()).disabled(!model.canControl)
    }
}

struct PlayerView: View {
    @Environment(\.appTypography) private var typography
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @AppStorage("playerControlsAlwaysVisible") private var controlsAlwaysVisible = false
    @AppStorage("playerWindowPinned") private var pinned = false
    @AppStorage("playerShowsPinButton") private var showPinButton = false
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("playerShowsProgress") private var showProgress = true
    @AppStorage("playerLyricsDisplayMode") private var lyricsDisplayMode = "automatic"
    @ObservedObject var model: ReceiverModel
    @Environment(\.colorSchemeContrast) private var colorContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pointerInside = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var showMiniControls: Bool { hovering || controlsAlwaysVisible || voiceOver || model.playerInteractionActive }
    private var playing: Bool { model.snapshot?.phase == .playing }
    private var hasTrack: Bool {
        guard let state = model.snapshot, state.controlsAvailable else { return false }
        return state.phase == .playing || state.phase == .paused
            || !state.trackId.isEmpty || !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (state.durationMs ?? 0) > 0
    }
    private var showLyrics: Bool {
        (LyricsDisplayMode(rawValue: lyricsDisplayMode) ?? .automatic).isVisible(hasLyrics: model.lyricsAvailable)
    }
    private func horizontalInset(for width: CGFloat) -> CGFloat {
        min(80, 36 + max(0, width - 600) * 0.1)
    }
    private func lyricsColumnSpacing(for width: CGFloat) -> CGFloat {
        32 + min(16, max(0, width - 600) * 0.1)
    }
    private var displayMetadata: DisplayMetadata {
        if correctLyricTitles { return model.correctedDisplayMetadata }
        return DisplayMetadata(title: model.snapshot?.title ?? "", artist: model.snapshot?.artist ?? "", album: model.snapshot?.album ?? "")
    }
    private var title: String {
        if !displayMetadata.title.isEmpty { return displayMetadata.title }
        return model.snapshot?.controlsAvailable == true ? L("手机正在投送") : L("等待你的音乐")
    }
    private var artist: String {
        if !displayMetadata.artist.isEmpty { return displayMetadata.artist }
        if model.snapshot?.controlsAvailable == true { return "" }
        return model.wantsReceiving ? L("在手机妙播中选择这台 Mac") : L("可在菜单栏开启接收")
    }
    private var album: String {
        displayMetadata.album.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let compact = geometry.size.width < 600
            ZStack {
                if !hasTrack {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.28))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel(L("等待你的音乐"))
                } else if compact { mini(size: geometry.size).transition(.opacity) }
                else { expanded(size: geometry.size).transition(.opacity) }
            }.animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: compact)
            PlayerWindowBehavior(square: compact && !showLyrics,
                                 miniRequest: model.miniPlayerRequest, miniLyrics: showLyrics,
                                 dimButtons: compact && !showMiniControls,
                                 pinned: pinned, duration: reduceMotion ? 0 : (showMiniControls ? 0.25 : 0.65))
                .frame(width: 0, height: 0)
        }.frame(minWidth: 260, minHeight: 260)
            .ignoresSafeArea(.container, edges: .top)
            .foregroundStyle(.white)
            .background { backdrop.ignoresSafeArea() }
            .environment(\.colorScheme, .dark)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showPlaybackControls)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showProgress)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: showLyrics)
    }
    private func expanded(size: CGSize) -> some View {
        let inset = horizontalInset(for: size.width)
        let gap = lyricsColumnSpacing(for: size.width)
        let availableWidth = max(0, size.width - inset * 2)
        let column = min(330, size.width * 0.38)
        let reserved: CGFloat = 72 + (showProgress ? 36 : 0) + (showPlaybackControls ? 44 : 0)
        let padding: CGFloat = size.height < 360 ? 20 : 32
        let standardSide = min(360, size.height - 48, size.width * 0.37)
        let side = showLyrics ? max(60, min(column, size.height - padding * 2 - reserved)) : standardSide
        let detailWidth = min(440, max(0, availableWidth - standardSide - 28))
        let albumWidth = showLyrics ? column : standardSide + 28 + detailWidth
        let lyricsWidth = max(0, availableWidth - column - gap)
        let albumLayout = showLyrics
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
        return HStack(spacing: showLyrics ? gap : 0) {
            // AnyLayout moves the same cover/details between horizontal and
            // vertical arrangements instead of replacing the player subtree.
            albumLayout {
                cover(side: side).frame(width: showLyrics ? column : side)
                expandedDetails
                    .frame(width: showLyrics ? column : detailWidth)
                    .frame(height: showLyrics ? nil : side)
            }.frame(width: albumWidth)
            // Keep the lyric viewport and its scroll identity alive at their
            // reading width while the surrounding slot collapses and fades.
            lyricsPanel(compact: false)
                .frame(width: lyricsWidth, height: max(0, size.height - padding * 2))
                .frame(width: showLyrics ? lyricsWidth : 0, alignment: .leading)
                .mask { Rectangle().padding(.horizontal, -24) }
                .opacity(showLyrics ? 1 : 0)
                .offset(x: showLyrics ? 0 : max(0, (size.width - albumWidth) / 2))
                .allowsHitTesting(showLyrics).accessibilityHidden(!showLyrics)
        }.padding(.horizontal, inset).padding(.vertical, showLyrics ? padding : 0)
            .frame(width: size.width, height: size.height, alignment: .center)
    }
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: showLyrics ? 5 : 9) {
                Text(title).font(typography.font(size: showLyrics ? 20 : 28, weight: .semibold))
                    .lineLimit(showLyrics ? 1 : 2).textSelection(.enabled).help(title)
                if !subtitle.isEmpty {
                    Text(subtitle).font(typography.font(size: showLyrics ? 12 : 14))
                        .foregroundStyle(.white.opacity(showLyrics ? 0.7 : 0.72))
                        .lineLimit(1).help(subtitle)
                }
            }.frame(maxWidth: .infinity, minHeight: showLyrics ? nil : 86, alignment: .topLeading)
                .padding(.top, showLyrics ? 14 : 0).padding(.bottom, showLyrics ? 10 : 0)
            if !showLyrics {
                Spacer(minLength: 18)
                if !model.error.isEmpty {
                    Label {
                        Text(model.error).font(typography.font(size: 11))
                    } icon: {
                        Image(systemName: "exclamationmark.circle").font(.system(size: 11))
                    }.foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2).help(model.error).padding(.bottom, 10)
                }
            }
            progress
            expandedTransport
        }
    }
    @ViewBuilder private var expandedTransport: some View {
        if showLyrics {
            miniTransport.transition(.opacity)
        } else {
            HStack(spacing: 28) {
                Spacer(minLength: 0)
                transport("backward.end.fill", label: L("上一曲")) { model.control(.previous) }
                Button { model.togglePlayback() } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: playing)
                        .font(.system(size: 23, weight: .semibold))
                        .offset(x: playing ? 0 : 1)
                        .frame(width: 62, height: 62)
                        .modifier(PlayerGlass())
                }.buttonStyle(PlayerTransportStyle()).disabled(!model.canControl)
                    .opacity(model.canControl ? 1 : 0.45)
                    .help(playing ? L("暂停") : L("播放")).accessibilityLabel(playing ? L("暂停") : L("播放"))
                transport("forward.end.fill", label: L("下一曲")) { model.control(.next) }
                Spacer(minLength: 0)
            }.frame(height: 62)
                .frame(height: showPlaybackControls ? 62 : 0, alignment: .top).clipped()
                .opacity(showPlaybackControls ? 1 : 0)
                .allowsHitTesting(showPlaybackControls).accessibilityHidden(!showPlaybackControls)
                .padding(.top, showPlaybackControls ? 6 : 0)
                .transition(.opacity)
        }
    }
    private func mini(size: CGSize) -> some View {
        let showControls = showMiniControls
        let coverHeight = showLyrics ? size.width : size.height
        let coverSize = CGSize(width: size.width, height: coverHeight)
        let artworkMode: ContentMode = showLyrics ? .fit : .fill
        let lyricsHeight = max(128, size.height - size.width - 8)
        return VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                if let artwork = model.artwork {
                    ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: artworkMode)
                        .frame(width: size.width, height: coverHeight).clipped()
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "music.note").font(.system(size: showLyrics ? 56 : 64, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(showLyrics ? 0.35 : 0.4))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(typography.font(size: showLyrics ? (size.width < 320 ? 17 : 20) : 19, weight: .semibold))
                        .lineLimit(showLyrics ? 1 : 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentTransition(.opacity)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(typography.font(size: 12))
                            .foregroundStyle(.white.opacity(showLyrics ? 0.7 : 0.75))
                            .lineLimit(1).help(subtitle).padding(.top, showLyrics ? 4 : 5)
                            .contentTransition(.opacity)
                    }
                    progress.padding(.top, showProgress ? 8 : 0)
                    miniTransport.padding(.top, !showLyrics && showPlaybackControls ? 2 : 0)
                }.padding(16)
                    .background {
                        GeometryReader { geometry in
                            miniBackdrop(size: coverSize, controlsHeight: geometry.size.height, artworkMode: artworkMode)
                                .offset(y: geometry.size.height - coverHeight)
                                .opacity(showControls ? 1 : 0)
                                .animation(reduceMotion ? nil : .easeInOut(duration: showControls ? 0.42 : 0.65)
                                    .delay(showControls ? 0 : 0.08), value: showControls)
                        }.allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .opacity(showControls ? 1 : 0)
                    .allowsHitTesting(showControls).accessibilityHidden(!showControls)
                    .animation(reduceMotion ? nil : .easeInOut(duration: showControls ? 0.36 : 0.42)
                        .delay(showControls ? 0.1 : 0), value: showControls)
            }.frame(width: size.width, height: coverHeight).clipped()
            // Retain the lyric pane's spacing without painting a hairline
            // below the cover, which looked like a misaligned material edge.
            Color.clear.frame(height: showLyrics ? 8 : 0)
                .accessibilityHidden(true)
            lyricsPanel(compact: true)
                .padding(.horizontal, size.width < 320 ? 16 : 22).padding(.bottom, 12)
                .frame(width: size.width, height: lyricsHeight)
                .frame(height: showLyrics ? lyricsHeight : 0, alignment: .top)
                .clipped().opacity(showLyrics ? 1 : 0)
                .allowsHitTesting(showLyrics).accessibilityHidden(!showLyrics)
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
                        .animation(reduceMotion ? nil : .easeInOut(duration: showControls ? 0.36 : 0.42)
                            .delay(showControls ? 0.1 : 0), value: showControls)
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: title)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: subtitle)
    }
    private func lyricsPanel(compact: Bool) -> some View {
        let track = model.snapshot?.trackId
        let trackTitle = model.snapshot?.title
        return LyricsView(document: model.lyrics, positionMs: model.displayedPositionMs,
                          loading: model.lyricsLoading, connected: model.snapshot?.controlsAvailable == true,
                          compact: compact, canSeek: model.canSeek) { position in
            // A row from a disappearing track must not seek the newly selected one.
            let sameTrack = (track?.isEmpty == false) ? track == model.snapshot?.trackId : trackTitle == model.snapshot?.title
            guard sameTrack else { return }
            model.seek(to: position)
        }.id((track?.isEmpty == false ? track : trackTitle) ?? "")
    }
    private var miniTransport: some View {
        HStack {
            Spacer(minLength: 0)
            transport("backward.end.fill", label: L("上一曲")) { model.control(.previous) }
            transport(playing ? "pause.fill" : "play.fill", label: playing ? L("暂停") : L("播放")) { model.togglePlayback() }
            transport("forward.end.fill", label: L("下一曲")) { model.control(.next) }
            Spacer(minLength: 0)
        }.frame(height: 44)
            .frame(height: showPlaybackControls ? 44 : 0, alignment: .top).clipped()
            .opacity(showPlaybackControls ? 1 : 0)
            .allowsHitTesting(showPlaybackControls).accessibilityHidden(!showPlaybackControls)
    }
    private func miniBackdrop(size: CGSize, controlsHeight: CGFloat, artworkMode: ContentMode = .fill) -> some View {
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
                    ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: artworkMode)
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
    @ViewBuilder private var backdrop: some View {
        if hasTrack {
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
        } else {
            IdlePlayerBackdrop().accessibilityHidden(true)
        }
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
        PlaybackProgressView(model: model, visible: showProgress)
            .frame(height: showProgress ? 36 : 0, alignment: .top).clipped()
            .opacity(showProgress ? 1 : 0)
            .allowsHitTesting(showProgress).accessibilityHidden(!showProgress)
    }
    private func transport(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: symbol)
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
        }.blur(radius: loading ? 10 : 0)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: loading)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: configuration.isPressed)
    }
}
