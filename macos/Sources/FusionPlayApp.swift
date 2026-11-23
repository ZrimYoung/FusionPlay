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
        sender.unhide(nil)
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
    init() { LyricsDisplayMode.migrateLegacyPreference(); NarrowPlayerLayout.migrateLegacyPreference() }
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
                NSApp.unhide(nil)
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
                NSApp.unhide(nil)
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

@MainActor
struct PlayerView: View {
    @Environment(\.appTypography) private var typography
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @AppStorage("playerControlsAlwaysVisible") private var controlsAlwaysVisible = false
    @AppStorage("playerWindowPinned") private var pinned = false
    @AppStorage("playerShowsPinButton") private var showPinButton = false
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @AppStorage("playerShowsTransport") private var legacyShowPlaybackControls = true
    @AppStorage("playerShowsProgress") private var legacyShowProgress = true
    @AppStorage("coverPlayerShowsTransport") private var coverShowPlaybackControls: Bool?
    @AppStorage("coverPlayerShowsProgress") private var coverShowProgress: Bool?
    @AppStorage("albumPlayerShowsTransport") private var albumShowPlaybackControls: Bool?
    @AppStorage("albumPlayerShowsProgress") private var albumShowProgress: Bool?
    @AppStorage("playerLyricsDisplayMode") private var lyricsDisplayMode = "automatic"
    @AppStorage("playerShowsLyricsButton") private var showLyricsButton = true
    @AppStorage("wrapPlayerMetadata") private var wrapPlayerMetadata = false
    @AppStorage(NarrowPlayerLayout.storageKey) private var narrowPlayerLayout = NarrowPlayerLayout.original.rawValue
    @AppStorage("coverLyricsExpandedByDragging") private var coverLyricsExpandedByDragging = false
    @AppStorage("lyricsPageShowsArtwork") private var lyricsPageShowsArtwork = true
    @AppStorage("lyricsPageShowsTrackInfo") private var lyricsPageShowsTrackInfo = true
    @ObservedObject var model: ReceiverModel
    @State private var responsiveMotion: PlayerResponsiveMotionDriver
    init(model: ReceiverModel, responsiveMotion: PlayerResponsiveMotionDriver? = nil) {
        self.model = model
        _responsiveMotion = State(initialValue: responsiveMotion ?? PlayerResponsiveMotionDriver())
    }
    @Environment(\.colorSchemeContrast) private var colorContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var pointerInside = false
    @State private var lyricsVisibility = PlayerLyricsVisibilityState()
    @State private var compactPage = CompactPlayerPage.playback
    @State private var coverLyricsResizing = false
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var showMiniControls: Bool { hovering || controlsAlwaysVisible || voiceOver || model.playerInteractionActive }
    private var playing: Bool { model.snapshot?.phase == .playing }
    private var hasTrack: Bool {
        guard let state = model.snapshot, state.controlsAvailable else { return false }
        return state.phase == .playing || state.phase == .paused
            || !state.trackId.isEmpty || !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (state.durationMs ?? 0) > 0
    }
    private var lyricMode: LyricsDisplayMode { LyricsDisplayMode(rawValue: lyricsDisplayMode) ?? .automatic }
    private var showLyrics: Bool {
        if narrowLayout == .original && coverLyricsExpandedByDragging { return true }
        return lyricsVisibility.isVisible(mode: lyricMode, hasLyrics: model.lyricsAvailable)
    }
    private var stableTrackID: String { model.snapshot?.trackId ?? "" }
    private var connected: Bool { model.snapshot?.controlsAvailable == true }
    private var narrowLayout: NarrowPlayerLayout { NarrowPlayerLayout.resolve(narrowPlayerLayout) }
    private var showPlaybackControls: Bool {
        (narrowLayout.isCover ? coverShowPlaybackControls : albumShowPlaybackControls) ?? legacyShowPlaybackControls
    }
    private var showProgress: Bool {
        (narrowLayout.isCover ? coverShowProgress : albumShowProgress) ?? legacyShowProgress
    }
    private var narrowPresentationLayout: NarrowPlayerLayout {
        narrowLayout.isCover && !showLyrics ? .squarePaged : narrowLayout
    }
    private func horizontalInset(for width: CGFloat) -> CGFloat {
        min(80, 36 + max(0, width - 600) * 0.1)
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
#if FUSIONPLAY_REFLOW_BENCHMARK
        let _ = NativeLyricsReflowBenchmark.hit("playerRootEvaluations")
#endif
        GeometryReader { geometry in
            let compact = geometry.size.width < 600
            ZStack {
                if !hasTrack {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.28))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .accessibilityLabel(L("等待你的音乐"))
                } else {
                    responsivePlayer(size: geometry.size)
                }
            }
            PlayerWindowBehavior(square: compact && (narrowLayout == .squarePaged || (narrowLayout == .original && !showLyrics)),
                                 miniRequest: model.miniPlayerRequest, miniLyrics: showLyrics,
                                 dimButtons: compact && !showMiniControls,
                                 pinned: pinned, duration: reduceMotion ? 0 : (showMiniControls ? 0.25 : 0.65),
                                 layoutMode: narrowPresentationLayout, coverLyricsResizing: coverLyricsResizing, hasTrack: hasTrack,
                                 scalesCoverProportionally: narrowLayout.isCover)
                .frame(width: 0, height: 0)
        }.overlay(alignment: .topTrailing) {
            GeometryReader { geometry in
                if hasTrack {
                    playerTools(compact: geometry.size.width < 600,
                                paged: NarrowPlayerPresentation.isPaged(width: geometry.size.width, layout: narrowPresentationLayout))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }.allowsHitTesting(hasTrack)
        }.overlay(alignment: .bottom) {
            GeometryReader { geometry in
                if hasTrack && narrowLayout.isCover && geometry.size.width < NarrowPlayerPresentation.breakpoint {
                    CoverLyricsResizeHandle(expanded: narrowLayout == .original && showLyrics,
                        onDraggingChanged: { active in
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { coverLyricsResizing = active }
                        },
                        onExpansionChanged: setCoverLyricsExpanded)
                        .frame(height: 14)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }.frame(minWidth: 260, minHeight: 260)
            .ignoresSafeArea(.container, edges: .top)
            .foregroundStyle(.white)
            .background { backdrop.ignoresSafeArea() }
#if FUSIONPLAY_UI_CHECKS
            .background {
                PlayerAppearanceCheckProbe(snapshot: PlayerAppearanceCheckSnapshot(
                    cover: narrowLayout.isCover, transport: showPlaybackControls, progress: showProgress,
                    lyricsArtwork: narrowLayout == .ipadPaged && lyricsPageShowsArtwork,
                    lyricsInfo: narrowLayout == .ipadPaged && lyricsPageShowsTrackInfo))
                    .frame(width: 0, height: 0)
            }
#endif
            .environment(\.colorScheme, .dark)
            .modifier(PlayerFullScreenEligibility())
            .onAppear { lyricsVisibility.observe(trackID: stableTrackID, connected: connected) }
            .onChange(of: stableTrackID) { _, id in
                lyricsVisibility.observe(trackID: id, connected: connected)
            }
            .onChange(of: connected) { _, value in
                lyricsVisibility.observe(trackID: stableTrackID, connected: value)
                if !value { compactPage = .playback }
            }
            .onChange(of: lyricsDisplayMode) { _, value in
                lyricsVisibility.reset()
                coverLyricsExpandedByDragging = false
                if narrowLayout.isCover && (LyricsDisplayMode(rawValue: value) ?? .automatic) == .automatic {
                    narrowPlayerLayout = NarrowPlayerLayout.original.rawValue
                }
            }
            .onHover { inside in
                pointerInside = inside
                if inside { hovering = true }
            }
            .task(id: pointerInside) {
                guard !pointerInside else { return }
                do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                hovering = false
            }
            .onChange(of: hasTrack) { _, value in if !value { responsiveMotion.stop() } }
            .onDisappear { pointerInside = false; hovering = false; responsiveMotion.stop() }
    }
    private func responsivePlayer(size: CGSize) -> some View {
        let compact = size.width < NarrowPlayerPresentation.breakpoint
        let expandedCover = narrowLayout == .original && showLyrics
        let paging = compact && !expandedCover && !coverLyricsResizing
        let playbackActive = !compact || expandedCover || compactPage == .playback
        let coverTitleSize: CGFloat = size.width < 320 ? 17 : 20
        let budget = PlayerMetadataLineBudget(
            availableHeight: max(0, size.width - 32 - (showProgress ? 44 : 0) - (showPlaybackControls ? 46 : 0) - 6),
            titleLineHeight: NSLayoutManager().defaultLineHeight(for: typography.nsFont(size: coverTitleSize, weight: .semibold)),
            subtitleLineHeight: NSLayoutManager().defaultLineHeight(for: typography.nsFont(size: 12)),
            spacing: 5, hasSubtitle: !subtitle.isEmpty)
        let target = PlayerResponsiveLayout(size: size, layout: narrowLayout, showLyrics: showLyrics,
            page: compactPage, showControls: showMiniControls, showsProgress: showProgress,
            showsTransport: showPlaybackControls, headerArtwork: lyricsPageShowsArtwork,
            headerInfo: lyricsPageShowsTrackInfo, wraps: wrapPlayerMetadata,
            coverTitleLines: budget.titleLines, coverSubtitleLines: budget.subtitleLines) { width, titleSize, subtitleSize, spacing, titleLines, subtitleLines in
#if FUSIONPLAY_REFLOW_BENCHMARK
                NativeLyricsReflowBenchmark.hit("playerMetadataMeasures")
#endif
                return PlayerTrackMetadataView.height(title: title, subtitle: subtitle, width: width,
                    titleFont: typography.nsFont(size: titleSize, weight: .semibold),
                    subtitleFont: typography.nsFont(size: subtitleSize), spacing: spacing,
                    wraps: wrapPlayerMetadata, wrappedTitleLines: titleLines, wrappedSubtitleLines: subtitleLines)
            }.pose
        let key = PlayerCanvasMotionKey(compact: compact, cover: narrowLayout.isCover,
            page: compactPage, lyrics: showLyrics, controls: !compact || !narrowLayout.isCover || showMiniControls,
            progress: showProgress, transport: showPlaybackControls, wraps: wrapPlayerMetadata,
            headerArtwork: lyricsPageShowsArtwork, headerInfo: lyricsPageShowsTrackInfo)
        let input = PlayerCanvasMotionInput(pose: target, key: key)
        let lyricActive = target[.lyrics].opacity > 0.5
        return ZStack(alignment: .topLeading) {
            // One playback subtree, including short-window native scrolling.
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    canvasArtwork(fills: compact && narrowLayout.isCover)
                        .canvasPlacement(.artwork, target: target, motion: responsiveMotion, interactive: playbackActive)
                    miniBackdrop(size: target[.coverBackdrop].frame.size, controlsHeight: target.controlsHeight)
                        .canvasPlacement(.coverBackdrop, target: target, motion: responsiveMotion, interactive: false)
                    PlayerTrackMetadataView(title: title, subtitle: subtitle, width: target[.metadata].frame.width,
                        titleSize: target.titleSize, subtitleSize: target.subtitleSize,
                        spacing: target.metadataSpacing, wrappedTitleLines: target.titleLines,
                        wrappedSubtitleLines: target.subtitleLines, subtitleOpacity: target.subtitleOpacity, allowsSelection: true)
                        .frame(width: target[.metadata].frame.width, height: target[.metadata].frame.height, alignment: .topLeading).clipped()
                        .background { if target[.metadata].opacity > 0.5 { PlayerPagingDragExclusion() } }
                        .canvasPlacement(.metadata, target: target, motion: responsiveMotion, interactive: playbackActive && target[.metadata].opacity > 0.5)
                    currentLyricSummary(active: compact && !narrowLayout.isCover && compactPage == .playback)
                        .canvasPlacement(.lyricSummary, target: target, motion: responsiveMotion, interactive: playbackActive && target[.lyricSummary].opacity > 0.5)
                    PlaybackProgressView(model: model, visible: playbackActive && showProgress && target[.progress].opacity > 0.5)
                        .canvasPlacement(.progress, target: target, motion: responsiveMotion, interactive: playbackActive && showProgress && target[.progress].opacity > 0.5)
                    canvasTransport("backward.end.fill", label: L("上一曲"), interactive: playbackActive && showPlaybackControls && target[.previous].opacity > 0.5) { model.control(.previous) }
                        .canvasPlacement(.previous, target: target, motion: responsiveMotion, interactive: playbackActive && showPlaybackControls && target[.previous].opacity > 0.5)
                    PlayerCanvasGlassVisual(motion: responsiveMotion, targetOpacity: target.glassOpacity) { glass in
                        canvasTransport(playing ? "pause.fill" : "play.fill", label: playing ? L("暂停") : L("播放"), glass: glass, interactive: playbackActive && showPlaybackControls && target[.playPause].opacity > 0.5) { model.togglePlayback() }
                    }
                        .canvasPlacement(.playPause, target: target, motion: responsiveMotion, interactive: playbackActive && showPlaybackControls && target[.playPause].opacity > 0.5)
                    canvasTransport("forward.end.fill", label: L("下一曲"), interactive: playbackActive && showPlaybackControls && target[.next].opacity > 0.5) { model.control(.next) }
                        .canvasPlacement(.next, target: target, motion: responsiveMotion, interactive: playbackActive && showPlaybackControls && target[.next].opacity > 0.5)
                }
                .frame(width: size.width, height: max(size.height, target.contentHeight), alignment: .topLeading)
                .background { PlayerPlaybackScrollIdentity() }
            }
            .scrollIndicators(.automatic).scrollContentBackground(.hidden)
            .frame(width: size.width, height: size.height)
            // The lyric viewport stays at this single call site; only its frame
            // changes. It is never a matched-geometry/compositor snapshot.
            lyricsPanel(compact: compact, presentationActive: lyricActive,
                geometryInteractionActive: coverLyricsResizing)
                .canvasPlacement(.lyrics, target: target, motion: responsiveMotion, interactive: lyricActive)
            Button { requestCompactPage(.playback) } label: { lyricsPageSummary(size: size) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fusionplay.player.lyrics.header")
                .accessibilityLabel(L("返回播放页"))
                .canvasPlacement(.lyricsHeader, target: target, motion: responsiveMotion, interactive: compact && compactPage == .lyrics && target[.lyricsHeader].opacity > 0.5)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading).clipped()
        .background { NarrowPlayerHorizontalScroll(requestPage: requestCompactPage, enabled: paging,
            allowsLyricDragging: paging && compactPage == .lyrics) }
        .onChange(of: input, initial: true) { _, value in
            responsiveMotion.move(to: value.pose, key: value.key, animated: !reduceMotion && !coverLyricsResizing)
        }
        .onChange(of: reduceMotion) { _, value in
            if value { responsiveMotion.move(to: target, key: key, animated: false) }
        }
        .onChange(of: coverLyricsResizing) { _, value in
            if value { responsiveMotion.move(to: target, key: key, animated: false) }
        }
    }
    private func canvasArtwork(fills: Bool) -> some View {
        ZStack {
            Rectangle().fill(.white.opacity(0.06))
            if let artwork = model.artwork {
                ArtworkSurface(artwork: artwork, loading: model.artworkLoading, mode: fills ? .fill : .fit)
            } else {
                Image(systemName: "music.note").font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .accessibilityLabel(model.artwork == nil ? L("暂无专辑封面") : L("专辑封面"))
#if FUSIONPLAY_UI_CHECKS
        .onAppear { PlayerCoverLifecycleCheck.appearances += 1 }
#endif
    }
    private func canvasTransport(_ symbol: String, label: String, glass: Double = 0,
                                 interactive: Bool, action: @escaping () -> Void) -> some View {
        ZStack {
            if glass > 0.001 {
                Color.clear.modifier(PlayerGlass()).opacity(glass).allowsHitTesting(false)
            }
            PlayerTransportButton(symbol: symbol, label: label, enabled: model.canControl,
                                  interactive: interactive, action: action)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(model.canControl ? 0.9 : 0.3)
    }
    private func setCoverLyricsExpanded(_ expanded: Bool) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            coverLyricsExpandedByDragging = expanded
            lyricsVisibility.request(expanded, mode: lyricMode, hasLyrics: model.lyricsAvailable)
            compactPage = .playback
            narrowPlayerLayout = (expanded ? NarrowPlayerLayout.original : .squarePaged).rawValue
        }
    }
    private func requestCompactPage(_ page: CompactPlayerPage) {
        compactPage = page
    }
    private func lyricsPageSummary(size: CGSize) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if lyricsPageShowsArtwork { cover(side: 56) }
            if lyricsPageShowsTrackInfo {
                PlayerTrackMetadataView(title: title, subtitle: subtitle,
                    width: max(0, size.width - 40 - (lyricsPageShowsArtwork ? 68 : 0)),
                    titleSize: 15, subtitleSize: 11, spacing: 3, wrappedTitleLines: 2)
            }
            if !lyricsPageShowsTrackInfo { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }
    private func currentLyricSummary(active: Bool) -> some View {
        TimelineView(.animation(minimumInterval: 0.15, paused: !playing || !active)) { _ in
            let current = PlayerCurrentLyricSummary.text(document: model.lyrics, positionMs: model.displayedPositionMs)
            let emptyCaption = model.lyrics.lines.isEmpty ? L("暂无歌词") : L("查看歌词")
            let caption = model.lyricsLoading ? L("正在载入歌词…") : (current ?? emptyCaption)
            Button { requestCompactPage(.lyrics) } label: {
                HStack(spacing: 8) {
                    Text(verbatim: caption).font(typography.font(size: 13))
                        .lineLimit(1).truncationMode(.tail).contentTransition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }.foregroundStyle(.white.opacity(current == nil ? 0.55 : 0.8))
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
                .background { PlayerPagingDragExclusion() }
                .accessibilityIdentifier("fusionplay.player.lyric-summary")
                .accessibilityLabel(L("查看歌词"))
                .accessibilityValue(caption)
                .help(L("点击当前歌词进入歌词页"))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: caption)
        }
    }
    private func playerTools(compact: Bool, paged: Bool) -> some View {
        HStack(spacing: 4) {
            if showLyricsButton {
                let selected = paged ? compactPage == .lyrics : showLyrics
                Button {
                    if paged { requestCompactPage(selected ? .playback : .lyrics) }
                    else {
                        coverLyricsExpandedByDragging = false
                        lyricsVisibility.request(!selected, mode: lyricMode, hasLyrics: model.lyricsAvailable)
                    }
                } label: {
                    Image(systemName: selected ? "quote.bubble.fill" : "quote.bubble")
                        .font(.system(size: 13, weight: .medium)).frame(width: 28, height: 28)
                }.buttonStyle(PlayerTransportStyle())
                    .accessibilityIdentifier("fusionplay.player.lyrics.toggle")
                    .help(L(paged ? (selected ? "返回播放页" : "切换到歌词页") : (selected ? "隐藏歌词（当前歌曲）" : "显示歌词（当前歌曲）")))
                    .accessibilityLabel(L(paged ? (selected ? "返回播放页" : "切换到歌词页") : (selected ? "隐藏歌词（当前歌曲）" : "显示歌词（当前歌曲）")))
                    .accessibilityValue(L(selected ? "已开启" : "已关闭"))
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            if compact && showPinButton {
                Button { pinned.toggle() } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12)).rotationEffect(.degrees(35)).frame(width: 28, height: 28)
                }.buttonStyle(PlayerTransportStyle())
                    .help(L(pinned ? "取消置顶" : "置顶窗口"))
                    .accessibilityLabel(L(pinned ? "取消置顶" : "置顶窗口"))
            }
        }.padding(10)
            .opacity(!compact || showMiniControls ? 1 : 0)
            .allowsHitTesting(!compact || showMiniControls)
            .accessibilityHidden(compact && !showMiniControls)
            .animation(reduceMotion ? nil : .easeInOut(duration: showMiniControls ? 0.36 : 0.42), value: showMiniControls)
    }
    private func lyricsPanel(compact: Bool, presentationActive: Bool = true, geometryInteractionActive: Bool = false) -> some View {
        let track = model.snapshot?.trackId
        let trackTitle = model.snapshot?.title
        return LyricsView(document: model.lyrics, positionMs: model.displayedPositionMs,
                          loading: model.lyricsLoading, connected: model.snapshot?.controlsAvailable == true,
                          compact: compact, canSeek: model.canSeek, presentationActive: presentationActive,
                          geometryInteractionActive: geometryInteractionActive || (compact && narrowLayout.isCover && coverLyricsResizing)) { position in
            // A row from a disappearing track must not seek the newly selected one.
            let sameTrack = (track?.isEmpty == false) ? track == model.snapshot?.trackId : trackTitle == model.snapshot?.title
            guard sameTrack else { return }
            model.seek(to: position)
        }.id((track?.isEmpty == false ? track : trackTitle) ?? "")
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
                    let start = fadeStart + (1 - fadeStart) * CGFloat(step) / 4
                    let end = fadeStart + (1 - fadeStart) * CGFloat(step + 1) / 4
                    CachedArtworkBlur(artwork: artwork, kind: .cover(step: step), loading: model.artworkLoading)
                        .frame(width: size.width, height: size.height)
                        .clipped()
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
                        CachedArtworkBlur(artwork: artwork, kind: .ambient, loading: model.artworkLoading)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .scaleEffect(1.15)
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

#if FUSIONPLAY_UI_CHECKS
// Observe the rendered cover lifecycle; zero-height native scroll views may be
// created or released by SwiftUI without replacing the visible cover itself.
enum PlayerCoverLifecycleCheck {
    static var appearances = 0
}
#endif

#if FUSIONPLAY_UI_CHECKS
struct PlayerAppearanceCheckSnapshot: Equatable {
    let cover: Bool
    let transport: Bool
    let progress: Bool
    let lyricsArtwork: Bool
    let lyricsInfo: Bool
}
@MainActor enum PlayerAppearanceCheckState {
    static var latest: PlayerAppearanceCheckSnapshot?
}
private struct PlayerAppearanceCheckProbe: NSViewRepresentable {
    let snapshot: PlayerAppearanceCheckSnapshot
    func makeNSView(context: Context) -> NSView {
        PlayerAppearanceCheckState.latest = snapshot
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) { PlayerAppearanceCheckState.latest = snapshot }
}
#endif
