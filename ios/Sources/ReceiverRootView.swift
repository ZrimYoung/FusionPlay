import SwiftUI
import UIKit

/// The same receiver stays active while the settings sheet is open or while
/// an iPad window switches between full width and Split View.
@MainActor
struct ReceiverRootView: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage(LyricsDisplayMode.storageKey) private var lyricsDisplayMode: LyricsDisplayMode = .never
    @AppStorage("narrowPlayerPaging") private var narrowPlayerPaging = false
    @AppStorage("lyricsPageShowsArtwork") private var lyricsPageShowsArtwork = true
    @AppStorage("lyricsPageShowsTrackInfo") private var lyricsPageShowsTrackInfo = true
    @AppStorage("playerShowsProgress") private var showProgress = true
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("playerToolbarAlwaysVisible") private var toolbarAlwaysVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var compactMetadataMinimumWidth: CGFloat = 148
    @ScaledMetric(relativeTo: .caption) private var compactProgressMinimumWidth: CGFloat = 120
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var showingSettings = false
    @State private var showingVolume = false
    @State private var toolbarRevealed = true
    @State private var toolbarHideTask: Task<Void, Never>?
    @State private var playerMode: PlayerPresentationLayout.Mode?
    @State private var selectedPage = PlayerSection.player
    @State private var lyricVisibilityOverride: (track: String, visible: Bool)?

    private var pagingEnabled: Bool { UIDevice.current.userInterfaceIdiom == .pad && narrowPlayerPaging }

    private var hasTrack: Bool {
        guard let state = model.snapshot, state.controlsAvailable else { return false }
        return state.phase == .playing || state.phase == .paused || !state.trackId.isEmpty
            || !state.title.isEmpty || (state.durationMs ?? 0) > 0
    }

    private var trackKey: String { TrackIdentity(snapshot: model.snapshot).key }

    private var showLyrics: Bool {
        if lyricsDisplayMode == .automatic, let override = lyricVisibilityOverride,
           override.track == trackKey || (model.lyricsLoading && !override.visible) {
            return override.visible
        }
        return lyricsDisplayMode.isVisible(hasLyrics: model.lyricsAvailable)
    }

    private var toolbarCanHide: Bool {
        hasTrack && !toolbarAlwaysVisible && !voiceOver && !showingVolume && !showingSettings
    }

    private var toolbarVisible: Bool { !toolbarCanHide || toolbarRevealed }

    private var displayAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.36)
    }

    private var layoutAnimation: Animation? {
        reduceMotion ? nil : .timingCurve(0.22, 0.74, 0.26, 1, duration: 0.40)
    }

    private var lyricPanelTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: 0, y: 12))
    }

    var body: some View {
        GeometryReader { proxy in
            let headerGutter = PlayerPresentationLayout.horizontalInset(for: proxy.size.width)
            let paged = PlayerPresentationLayout.usesNarrowPaging(width: proxy.size.width, enabled: pagingEnabled)
            VStack(spacing: 0) {
                header(paged: paged).padding(.horizontal, headerGutter)
                GeometryReader { content in
                    if hasTrack {
                        let layout = PlayerPresentationLayout(
                            size: content.size,
                            showsLyrics: showLyrics,
                            accessibilitySize: dynamicTypeSize.isAccessibilitySize,
                            showsProgress: showProgress,
                            showsPlaybackControls: showPlaybackControls,
                            pagingEnabled: pagingEnabled
                        )
                        ZStack {
                            playerContent(layout, size: content.size)
                        }
                        .animation(displayAnimation, value: showLyrics)
                        .animation(displayAnimation, value: showProgress)
                        .animation(displayAnimation, value: showPlaybackControls)
                    } else {
                        ScrollView {
                            idleContent
                                .frame(maxWidth: 440)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: max(0, content.size.height - 48))
                                .padding(.horizontal, headerGutter)
                                .padding(.vertical, 24)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { revealToolbar() })
            .background { playerBackground }
            .tint(PlayerPalette.accent)
            .sheet(isPresented: $showingSettings) {
                ReceiverSettingsView(model: model, windowWidth: proxy.size.width)
            }
        }
        .preferredColorScheme(.dark)
        .receiverTypography()
        .onChange(of: toolbarCanHide, initial: true) { _, _ in revealToolbar() }
        .onChange(of: lyricsDisplayMode) { _, mode in
            if mode == .never { lyricVisibilityOverride = nil }
        }
        .onChange(of: trackKey) { _, _ in
            if !model.lyricsLoading || lyricVisibilityOverride?.visible != false {
                lyricVisibilityOverride = nil
            }
        }
        .onChange(of: model.lyricsLoading) { _, loading in
            if !loading, lyricVisibilityOverride?.track != trackKey {
                lyricVisibilityOverride = nil
            }
        }
        .onChange(of: hasTrack) { _, active in
            if !active {
                showingVolume = false
                selectedPage = .player
                lyricVisibilityOverride = nil
            }
        }
        .onDisappear { toolbarHideTask?.cancel() }
    }

    private func revealToolbar() {
        toolbarHideTask?.cancel()
        toolbarRevealed = true
        guard toolbarCanHide else { return }
        toolbarHideTask = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard toolbarCanHide else { return }
            toolbarRevealed = false
        }
    }

    private enum PlayerSection: Hashable {
        case player, lyrics

        var label: LocalizedStringKey {
            switch self {
            case .player: "播放页"
            case .lyrics: "歌词页"
            }
        }
    }

    private var pageSelection: Binding<PlayerSection?> {
        Binding(get: { selectedPage }, set: { if let page = $0 { selectedPage = page } })
    }

    private func playerContent(_ layout: PlayerPresentationLayout, size: CGSize) -> some View {
        let paged = layout.mode == .paged
        let lyricsBesidePlayer = layout.mode == .artworkAndLyrics
        let controlsBesideCover = layout.mode == .artworkAndControls
        let compact = layout.mode == .stacked || paged
        let playbackWidth = lyricsBesidePlayer ? layout.leadingWidth : layout.contentWidth
        let minimumDetailsWidth = max(
            compactMetadataMinimumWidth,
            showProgress ? compactProgressMinimumWidth : 0,
            showPlaybackControls ? Self.prominentTransportSize * 3 : 0
        )
        let compactDetailsWidth = min(playbackWidth, max(layout.coverSide, minimumDetailsWidth))
        let pageHeight = max(0, size.height)
        let viewportHeight = max(0, pageHeight - layout.verticalInset * 2)
        let lyricSize = CGSize(
            width: lyricsBesidePlayer ? max(0, layout.contentWidth - layout.leadingWidth - layout.gap) : layout.contentWidth,
            height: paged || lyricsBesidePlayer ? viewportHeight : layout.lyricsHeight
        )
        let panelLayout = paged || lyricsBesidePlayer
            ? AnyLayout(HStackLayout(alignment: .center, spacing: paged ? 0 : layout.gap))
            : AnyLayout(VStackLayout(alignment: .center, spacing: 30))
        let controlsLayout = controlsBesideCover
            ? AnyLayout(HStackLayout(alignment: .center, spacing: layout.gap))
            : AnyLayout(VStackLayout(alignment: .center, spacing: lyricsBesidePlayer ? 22 : 24))
        let playback = controlsLayout {
            cover(side: layout.coverSide)
                .geometryGroup()
                .frame(width: controlsBesideCover ? layout.leadingWidth : nil)
            playbackDetails(paged: paged, compact: compact)
                .frame(width: compact ? compactDetailsWidth : nil)
                .frame(maxWidth: controlsBesideCover ? 420 : .infinity)
                .geometryGroup()
                .frame(maxWidth: .infinity)
        }
        .frame(width: playbackWidth)

        return ScrollViewReader { reader in
            ScrollView(paged ? .horizontal : .vertical) {
                panelLayout {
                    // Keep the playback subtree mounted across resize. Outside
                    // pagination the inner viewport fits its content and lets
                    // the outer scroll view handle vertical navigation.
                    ScrollView {
                        playback
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: paged ? viewportHeight : nil)
                            .padding(.vertical, paged ? layout.verticalInset : 0)
                    }
                    .scrollDisabled(!paged)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollClipDisabled(!paged)
                    .fixedSize(horizontal: false, vertical: !paged)
                    .frame(width: paged ? size.width : playbackWidth, height: paged ? pageHeight : nil)
                    .id(PlayerSection.player)

                    if paged || showLyrics {
                        lyricPanel(mode: layout.mode)
                            .frame(width: lyricSize.width, height: lyricSize.height)
                            .padding(.vertical, paged ? layout.verticalInset : 0)
                            .frame(width: paged ? size.width : nil, height: paged ? pageHeight : nil)
                            .animation(nil, value: lyricSize)
                            .geometryGroup()
                            .id(PlayerSection.lyrics)
                            .transition(lyricPanelTransition)
                    }
                }
                // Scope resize motion to panel placement. The enclosing
                // scroll viewport changes axes and anchors immediately.
                .animation(layoutAnimation, value: layout.mode)
                .scrollTargetLayout(isEnabled: paged)
                .frame(width: paged ? nil : layout.contentWidth)
                .frame(maxWidth: .infinity)
                .frame(minHeight: paged ? pageHeight : viewportHeight)
                .padding(.vertical, paged ? 0 : layout.verticalInset)
            }
            .scrollBounceBehavior(.basedOnSize, axes: paged ? [.horizontal, .vertical] : .vertical)
            .scrollIndicators(paged ? .hidden : .automatic, axes: .horizontal)
            .modifier(PlayerScrollBehavior(paged: paged))
            .scrollPosition(id: paged ? pageSelection : .constant(nil), anchor: .leading)
            .onChange(of: layout.mode, initial: true) { _, mode in
                playerMode = mode
            }
            .onChange(of: showLyrics) { _, shown in
                guard layout.mode == .stacked else { return }
                scrollPlayer(reader, towardLyrics: shown)
            }
        }
    }

    private func lyricPanel(mode: PlayerPresentationLayout.Mode) -> some View {
        let title = model.displayTitle
        let subtitle = model.displaySubtitle
        let hasTrackInfo = lyricsPageShowsTrackInfo && (!title.isEmpty || !subtitle.isEmpty)
        let showsHeader = mode == .paged && (lyricsPageShowsArtwork || hasTrackInfo)

        return VStack(spacing: 0) {
            Button { selectPage(.player) } label: {
                CompactLyricsTrackHeader(
                    artwork: model.artwork,
                    title: title,
                    subtitle: subtitle,
                    showsArtwork: lyricsPageShowsArtwork,
                    showsTrackInfo: lyricsPageShowsTrackInfo
                )
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回播放页")
            .accessibilityValue(Text(verbatim: hasTrackInfo ? [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ") : ""))
            .accessibilityIdentifier("player.lyrics.return")
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
            .opacity(showsHeader ? 1 : 0)
            .offset(y: showsHeader || reduceMotion ? 0 : -7)
            .animation(layoutAnimation, value: showsHeader)
            // Apply the slot height immediately so this transition only
            // moves the header and doesn't reflow the lyrics each frame.
            .frame(height: showsHeader ? nil : 0, alignment: .top)
            .animation(nil, value: showsHeader)
            .allowsHitTesting(showsHeader)
            .accessibilityHidden(!showsHeader)

            lyricsPane
        }
    }

    private func selectPage(_ page: PlayerSection) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.02)) {
            selectedPage = page
        }
    }

    private func scrollPlayer(_ reader: ScrollViewProxy, towardLyrics: Bool) {
        DispatchQueue.main.async {
            guard playerMode == .stacked, showLyrics == towardLyrics else { return }
            withAnimation(displayAnimation) {
                reader.scrollTo(towardLyrics ? PlayerSection.lyrics : PlayerSection.player,
                                anchor: towardLyrics ? .bottom : .top)
            }
        }
    }

    private func header(paged: Bool) -> some View {
        let lyricsSelected = paged ? selectedPage == .lyrics : showLyrics
        let lyricAction = paged ? (lyricsSelected ? PlayerSection.player.label : PlayerSection.lyrics.label)
            : (lyricsSelected ? LocalizedStringKey("隐藏歌词") : LocalizedStringKey("显示歌词"))
        return HStack(spacing: 6) {
            if !hasTrack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FusionPlay").font(.headline.weight(.bold))
                    statusLabel.font(.caption)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if hasTrack {
                    headerButton(lyricsSelected ? "quote.bubble.fill" : "quote.bubble",
                                 label: lyricAction, selected: lyricsSelected) {
                        revealToolbar()
                        if paged {
                            selectPage(lyricsSelected ? .player : .lyrics)
                        } else {
                            let visible = !lyricsSelected
                            withAnimation(displayAnimation) {
                                if lyricsDisplayMode == .never {
                                    lyricsDisplayMode = .automatic
                                }
                                lyricVisibilityOverride = (trackKey, visible)
                            }
                        }
                    }
                }
                ReceiverVolumeControl(model: model, showingVolume: $showingVolume)
                headerButton("gearshape", label: "接收设置") { showingSettings = true }
            }
            .opacity(toolbarVisible ? 1 : 0)
            .animation(displayAnimation, value: toolbarVisible)
            .allowsHitTesting(toolbarVisible)
            .accessibilityHidden(!toolbarVisible)
        }
        .padding(.vertical, 7)
    }

    private var statusLabel: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.error.isEmpty ? (model.wantsReceiving ? PlayerPalette.accent : .secondary) : Color.orange)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(model.statusText)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func headerButton(
        _ image: String,
        label: LocalizedStringKey,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.white.opacity(selected ? 0.12 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var playerBackground: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.09, green: 0.17, blue: 0.20), PlayerPalette.background],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                PlayerArtworkBackdrop(
                    artwork: hasTrack ? model.artwork?.cgImage : nil,
                    retainsWhileLoading: hasTrack && (model.artworkStatus == .loading || model.artworkStatus == .retrying)
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
                .opacity(0.45)
                LinearGradient(
                    colors: [PlayerPalette.background.opacity(0.12), PlayerPalette.background.opacity(0.80)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var idleContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 43, weight: .light))
                .foregroundStyle(PlayerPalette.accent)
                .frame(width: 106, height: 106)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 28))
                .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.11)) }
                .accessibilityHidden(true)
            if model.snapshot?.phase == .ready && model.error.isEmpty {
                Text(model.name)
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .textSelection(.enabled)
                Text("在小米妙播的设备列表中选择")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !model.wantsReceiving {
                Text("妙播接收")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .padding(.top, 4)
                Button { model.start() } label: {
                    Label("开始接收", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(PlayerPalette.background)
                .disabled(model.busy)
            }
            if model.busy {
                ProgressView().accessibilityLabel("正在更新接收状态")
            }
            if !model.error.isEmpty {
                Label(model.error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.vertical, 10)
    }

    private func playbackDetails(paged: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 0) {
                PlayerTrackMetadataView(title: model.displayTitle, subtitle: model.displaySubtitle, trackKey: trackKey)
                lyricPageLink(visible: paged)
                    .padding(.top, 13)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: paged ? nil : 0, alignment: .top)
                    .clipped()
                    .opacity(paged ? 1 : 0)
                    .allowsHitTesting(paged)
                    .accessibilityHidden(!paged || selectedPage != .player)
            }
            if showProgress {
                ReceiverProgressView(model: model, prioritizesScrubbing: paged)
                    .geometryGroup()
                    .transition(.opacity)
            }
            if showPlaybackControls {
                transport(compact: compact).transition(.opacity)
            }
            if !model.controlMessage.isEmpty {
                Text(model.controlMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lyricPageLink(visible: Bool) -> some View {
        let document = model.lyrics
        let live = visible && selectedPage == .player && model.snapshot?.phase == .playing && document.isTimed
        return TimelineView(.animation(minimumInterval: 0.25, paused: !live)) { _ in
            let active = model.displayedPositionMs.flatMap { document.activeLineIndex(at: $0) }
            let current = active.map { document.lines[$0].text }
            let caption = current.map { $0.isEmpty ? "•••" : $0.replacingOccurrences(of: "\n", with: " ") }
            Button { selectPage(.lyrics) } label: {
                Group {
                    if model.lyricsLoading { Text("正在载入歌词…") }
                    else if let caption { Text(verbatim: caption) }
                    else { Text("查看歌词") }
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.76))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看歌词")
            .accessibilityValue(Text(verbatim: caption ?? ""))
            .accessibilityIdentifier("player.lyrics.open")
        }
    }

    private func cover(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(25, side * 0.058))
        return ZStack {
            shape.fill(Color(red: 0.09, green: 0.16, blue: 0.19).gradient)
            if let artwork = model.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .id(ObjectIdentifier(artwork))
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(60, side * 0.21), weight: .light))
                    .foregroundStyle(PlayerPalette.accent.opacity(0.66))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.13)) }
        .shadow(color: .black.opacity(0.32), radius: 20, y: 11)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: model.artwork.map(ObjectIdentifier.init))
        .accessibilityHidden(true)
    }

    private static let prominentTransportSize: CGFloat = 62

    private func transport(compact: Bool) -> some View {
        let playing = model.snapshot?.phase == .playing
        return HStack(spacing: 0) {
            transportButton("backward.end.fill", label: "上一曲") { model.control(.previous) }
            transportButton(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放", prominent: true) {
                model.togglePlayback()
            }
            transportButton("forward.end.fill", label: "下一曲") { model.control(.next) }
        }
        .frame(maxWidth: compact ? .infinity : 326)
        .frame(maxWidth: .infinity)
        .disabled(!model.canControl)
        .opacity(model.snapshot?.controlsAvailable == true ? 1 : 0.45)
    }

    private func transportButton(_ image: String, label: LocalizedStringKey, prominent: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: image)
                    .font(.system(size: prominent ? 27 : 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .id(image)
                    .transition(.blurReplace(.downUp))
            }
            .animation(prominent && !reduceMotion ? .easeInOut(duration: 0.24) : nil, value: image)
            .frame(width: prominent ? Self.prominentTransportSize : 46,
                   height: prominent ? Self.prominentTransportSize : 46)
            .background(.white.opacity(prominent ? 0.14 : 0), in: Circle())
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(PlaybackButtonStyle())
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text(label))
    }

    private var lyricsPane: some View {
        ZStack {
            ReceiverLyricsView(model: model, trackKey: trackKey, document: model.lyrics)
                .id(trackKey)
                .transition(.opacity)
        }
        .animation(displayAnimation, value: trackKey)
    }
}

private struct PlaybackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct PlayerScrollBehavior: ViewModifier {
    let paged: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            let behavior = paged
                ? AnyScrollTargetBehavior(PagingScrollTargetBehavior())
                : AnyScrollTargetBehavior(CompatiblePlayerPagingBehavior(enabled: false))
            content.scrollTargetBehavior(behavior)
        } else {
            content.scrollTargetBehavior(CompatiblePlayerPagingBehavior(enabled: paged))
        }
    }
}

private struct CompatiblePlayerPagingBehavior: ScrollTargetBehavior {
    let enabled: Bool

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard enabled else { return }
        PagingScrollTargetBehavior().updateTarget(&target, context: context)
    }
}

private enum PlayerPalette {
    static let accent = Color(red: 0.57, green: 0.95, blue: 0.89)
    static let background = Color(red: 0.045, green: 0.067, blue: 0.077)
}

/// Guard gestures with the raw transport identity. A track change during a
/// drag must not move the new song to an old song's percentage.
struct TrackIdentity: Equatable, Hashable {
    var key: String
    var duration: UInt64?
    var connected: Bool
    init(snapshot: Snapshot?) {
        if let snapshot {
            key = snapshot.trackId.isEmpty ? snapshot.title : snapshot.trackId
            duration = snapshot.durationMs
            connected = snapshot.controlsAvailable
        } else {
            key = ""
            duration = nil
            connected = false
        }
    }
}

@MainActor
private struct ReceiverLyricsView: View {
    @ObservedObject var model: ReceiverModel
    let trackKey: String
    let document: LyricsDocument
    @AppStorage(LyricsTypography.storageKey) private var lyricScalePercent = LyricsTypography.defaultScalePercent
    @AppStorage(LyricsShadowAppearance.enabledKey) private var lyricShadowEnabled = false
    @AppStorage(LyricsShadowAppearance.opacityKey) private var lyricShadowOpacity = LyricsShadowAppearance.defaultOpacity
    @AppStorage(LyricsShadowAppearance.spreadKey) private var lyricShadowSpread = LyricsShadowAppearance.defaultSpread
    @AppStorage("staggerLyricMotion") private var staggerLyricMotion = true
    @AppStorage("lyricStaggerMilliseconds") private var lyricStaggerMilliseconds = LyricReflowTiming.defaultStaggerMilliseconds
    @AppStorage(LyricReflowTiming.moveStorageKey) private var lyricLineMoveMilliseconds = LyricReflowTiming.defaultMoveMilliseconds
    @Environment(\.receiverTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .title2) private var typeScale = 1.0
    @GestureState private var dragging = false
    @State private var scrollInMotion = false
    @State private var followRevision = 0
    @State private var following = true
    @State private var lastActiveIndex: Int?
    @State private var lyricAnchor: Int?
    @State private var showsEmptyState = false
    @State private var previousLayout: LayoutMetrics?
    @State private var isSettlingLayout = false
    @State private var followWave: LyricFollowWave?

    private struct LayoutMetrics: Equatable {
        let viewport: CGSize
        let fontSize: CGFloat
        let typography: ReceiverTypography
    }

    private var lineMoveDuration: TimeInterval {
        LyricReflowTiming.moveDuration(milliseconds: lyricLineMoveMilliseconds)
    }

    private var staggerSpan: TimeInterval {
        guard staggerLyricMotion, !reduceMotion, !voiceOver else { return 0 }
        return LyricReflowTiming.staggerSpan(milliseconds: lyricStaggerMilliseconds)
    }
    private var isCurrentTrack: Bool { TrackIdentity(snapshot: model.snapshot).key == trackKey }

    private func lyricScrollPosition(timed: Bool) -> Binding<Int?> {
        Binding(get: { lyricAnchor }, set: { line in
            // Geometry reports visible rows during resize. Accept them only
            // while browsing; during follow the playback cue owns the anchor.
            if (!timed || !following || voiceOver), let line { lyricAnchor = line }
        })
    }

    private static let viewport = "receiver.lyrics.viewport"
    private static let maximumBaseFontSize: CGFloat = 36
    private static let followAnchor = UnitPoint(x: 0.5, y: 0.32)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if document.lines.isEmpty {
                    if showsEmptyState {
                        emptyState.transition(.opacity)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let index = isCurrentTrack
                            ? model.displayedPositionMs.flatMap { document.activeLineIndex(at: $0) }
                            : lastActiveIndex
                        let activeIndex = index.flatMap { document.lines.indices.contains($0) ? $0 : nil }
                        lyricScroll(size: geometry.size, document: document, activeIndex: activeIndex)
                            .onChange(of: activeIndex, initial: true) { _, current in
                                if isCurrentTrack { lastActiveIndex = current }
                            }
                    }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: document.lines.isEmpty)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: showsEmptyState)
        }
        .allowsHitTesting(isCurrentTrack)
        .accessibilityHidden(!isCurrentTrack)
        .task {
            do { try await Task.sleep(for: .milliseconds(480)) } catch { return }
            showsEmptyState = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("歌词")
        .task(id: followWave?.start) {
            guard let wave = followWave else { return }
            do { try await Task.sleep(for: .seconds(max(0, wave.end.timeIntervalSinceNow))) }
            catch { return }
            if followWave?.start == wave.start { followWave = nil }
        }
        .onChange(of: staggerSpan) { _, _ in followWave = nil }
        .onChange(of: lineMoveDuration) { _, _ in followWave = nil }
        .task(id: followRevision) {
            guard !following, !dragging, !scrollInMotion, !voiceOver else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard !dragging, !scrollInMotion, !voiceOver else { return }
            following = true
        }
        .onChange(of: voiceOver) { _, _ in followRevision &+= 1 }
        .onChange(of: document.lines.isEmpty) { _, isEmpty in
            if isEmpty {
                scrollInMotion = false
                following = true
                previousLayout = nil
                lyricAnchor = nil
                isSettlingLayout = false
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.lyricsLoading {
                ProgressView()
                Text("正在载入歌词…")
            } else {
                Text("发送设备未提供歌词")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lyricScroll(size: CGSize, document: LyricsDocument, activeIndex: Int?) -> some View {
        let activeID = activeIndex.map { document.lines[$0].id }
        let allowsEffects = !reduceTransparency && !voiceOver && contrast != .increased
        let shadow = LyricsShadowAppearance(enabled: lyricShadowEnabled, opacityPercent: lyricShadowOpacity,
                                            spread: lyricShadowSpread)
        let bleed = max(allowsEffects ? 14 : 0, shadow.radius)
        let fontSize = min(Self.maximumBaseFontSize, max(26, size.width * 0.076)) * typeScale
            * LyricsTypography.scale(percent: lyricScalePercent)
        let layout = LayoutMetrics(viewport: size, fontSize: fontSize, typography: typography)
        let topBlur: CGFloat = allowsEffects ? 3.5 : 0
        let bottomBlur: CGFloat = allowsEffects ? 10 : 0
        let timed = document.isTimed

        return trackScroll(timed: timed) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: min(22, max(17, 17 + (size.width - 350) / 10))) {
                    ForEach(document.lines) { line in
                        lyricRow(line, activeID: activeID, timed: timed, fontSize: fontSize, shadow: shadow)
                            .modifier(LyricRowStagger(span: staggerSpan, viewport: Self.viewport,
                                                     viewportHeight: size.height, wave: followWave))
                            .visualEffect { [height = size.height, viewport = Self.viewport] content, row in
                                content.blur(radius: Self.edgeBlurRadius(
                                    middleY: row.frame(in: .named(viewport)).midY,
                                    height: height, top: topBlur, bottom: bottomBlur))
                            }
                            .id(line.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, bleed)
                .padding(.top, timed && !voiceOver ? max(12, size.height * 0.32) : 12)
                .padding(.bottom, timed && !voiceOver ? max(16, size.height * 0.68) : 16)
            }
        }
        .environment(\.lyricLineMoveDuration, lineMoveDuration)
        .coordinateSpace(name: Self.viewport)
        .scrollPosition(id: lyricScrollPosition(timed: timed), anchor: Self.followAnchor)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
        .mask {
            if allowsEffects {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.09),
                            .init(color: .black, location: 0.90), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                Rectangle()
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, -bleed)
        .onChange(of: activeID, initial: true) { previous, current in
            follow(to: current, animated: previous != current, from: previous)
        }
        .task(id: layout) {
            guard let prior = previousLayout else {
                previousLayout = layout
                return
            }
            guard prior != layout || isSettlingLayout else { return }
            if !reduceMotion && !voiceOver {
                isSettlingLayout = true
                let resizeDelay = LyricResizeTiming.staggerSpan(playbackSpan: staggerSpan)
                do { try await Task.sleep(for: .seconds(LyricResizeTiming.duration + resizeDelay + 0.05)) }
                catch { return }
            }
            isSettlingLayout = false
            previousLayout = layout
            let latest = model.lyrics
            let index = model.displayedPositionMs.flatMap { latest.activeLineIndex(at: $0) }
            let line = index.map { latest.lines[$0].id }
            follow(to: line, animated: false)
        }
        .onChange(of: following) { _, active in
            if active { follow(to: activeID, animated: true) }
        }
    }

    @ViewBuilder
    private func trackScroll<Content: View>(timed: Bool, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 18.0, *) {
            content()
                .onScrollPhaseChange { _, phase in
                    guard timed else { return }
                    let moving = phase == .interacting || phase == .decelerating
                    guard scrollInMotion != moving else { return }
                    scrollInMotion = moving
                    if moving {
                        following = false
                        followWave = nil
                    }
                    followRevision &+= 1
                }
        } else {
            content()
                .simultaneousGesture(DragGesture(minimumDistance: 12).updating($dragging) { _, active, _ in active = true })
                .onChange(of: dragging) { _, active in
                    guard timed else { return }
                    if active {
                        following = false
                        followWave = nil
                    }
                    followRevision &+= 1
                }
        }
    }

    @ViewBuilder
    private func lyricRow(_ line: LyricsLine, activeID: Int?, timed: Bool, fontSize: CGFloat,
                          shadow: LyricsShadowAppearance) -> some View {
        let active = line.id == activeID
        let opacity: Double = {
            if !timed { return 0.88 }
            if active { return 1 }
            if contrast == .increased { return 0.74 }
            guard let activeID else { return line.id == 0 ? 0.72 : 0.42 }
            return abs(line.id - activeID) <= 1 ? 0.57 : 0.32
        }()
        let textScale = fontSize / Self.maximumBaseFontSize
        let label = VStack(alignment: .leading, spacing: 6) {
            LyricReflowText(line.text.isEmpty ? "•••" : line.text, size: Self.maximumBaseFontSize,
                            scale: textScale, weight: .bold, lineSpacing: 2)
            if let translation = line.translation, !translation.isEmpty {
                LyricReflowText(translation, size: Self.maximumBaseFontSize * 0.60,
                                scale: textScale, weight: .semibold)
                    .opacity(0.78)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PlayerTextHeightMotion(
            wrapThreshold: fontSize * 0.45,
            stagesEnabled: line.text.utf8.count <= 1_024 && (line.translation?.utf8.count ?? 0) <= 1_024,
            animateContentChanges: false,
            verticalCurve: LyricReflowTiming.verticalMove
        ))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.opacity > 0 ? 2 : 0)
        .opacity(opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: active)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .multilineTextAlignment(.leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? .isSelected : [])
        if let timestamp = line.timeMs, !line.text.isEmpty {
            Button {
                guard isCurrentTrack, model.canSeek else { return }
                following = true
                model.seek(to: timestamp)
            } label: { label }
                .buttonStyle(PlaybackButtonStyle())
                // Waiting for a playback command must not dim every lyric row.
                .disabled(!model.canSeek)
                .accessibilityHint("跳到这一句")
        } else {
            label
        }
    }

    nonisolated private static func edgeBlurRadius(middleY: CGFloat, height: CGFloat, top: CGFloat, bottom: CGFloat) -> CGFloat {
        guard height > 0 else { return 0 }
        let topT = 1 - min(1, max(0, middleY / max(12, height * 0.30)))
        let bottomT = 1 - min(1, max(0, (height - middleY) / max(12, height * 0.45)))
        return max(top * topT * topT * (3 - 2 * topT), bottom * bottomT * bottomT * (3 - 2 * bottomT))
    }

    private func follow(to id: Int?, animated: Bool, from previous: Int? = nil) {
        guard isCurrentTrack, following, !isSettlingLayout, !dragging, !scrollInMotion,
              !voiceOver, let id, lyricAnchor != id else { return }
        let span = staggerSpan
        let moveDuration = lineMoveDuration
        if animated, span > 0, let previous, (1...2).contains(abs(id - previous)) {
            followWave = LyricFollowWave(start: Date(), direction: id > previous ? 1 : -1, span: span,
                                         duration: moveDuration, previous: followWave)
        } else {
            followWave = nil
        }
        let animation: Animation? = animated && !reduceMotion
            ? .timingCurve(LyricReflowTiming.verticalMove, duration: moveDuration) : nil
        withAnimation(animation) {
            lyricAnchor = id
        }
    }
}

private struct LyricRowStagger: ViewModifier {
    let span: TimeInterval
    let viewport: String
    let viewportHeight: CGFloat
    let wave: LyricFollowWave?

    private struct Location: Equatable {
        let rank: Int
        let isVisible: Bool
    }

    @State private var location = Location(rank: 0, isVisible: true)
    @State private var followRank: Int?
    @State private var resizeClock = LyricResizeClock()

    func body(content: Content) -> some View {
        let steps = Double(LyricReflowTiming.viewportSteps)
        let position = Double(location.rank) / steps
        let resize = LyricResizeContext(isVisible: location.isVisible,
                                       delay: LyricResizeTiming.staggerSpan(playbackSpan: span) * position,
                                       clock: resizeClock)
        let activeWave = span > 0 ? wave : nil
        let followPosition = Double(followRank ?? location.rank) / steps
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: activeWave == nil)) { context in
            content
                .environment(\.lyricResizeContext, resize)
                .offset(y: activeWave?.offset(at: context.date, position: followPosition) ?? 0)
        }
        .onChange(of: activeWave != nil, initial: true) { _, isFollowing in
            // Keep each row's delay stable while its viewport position is changing.
            followRank = isFollowing ? location.rank : nil
        }
        .onGeometryChange(for: Location.self) { geometry in
            let frame = geometry.frame(in: .named(viewport))
            guard viewportHeight.isFinite, viewportHeight > 0, frame.midY.isFinite else {
                return Location(rank: 0, isVisible: true)
            }
            let position = span > 0 ? min(1, max(0, frame.midY / viewportHeight)) : 0
            let rank = Int((position * CGFloat(LyricReflowTiming.viewportSteps)).rounded())
            return Location(rank: rank, isVisible: frame.maxY > 0 && frame.minY < viewportHeight)
        } action: { measured in
            location = measured
            if activeWave != nil, followRank == nil { followRank = measured.rank }
        }
    }
}

struct PlayerTextHeightMotion: ViewModifier {
    let wrapThreshold: CGFloat
    let stagesEnabled: Bool
    let animateContentChanges: Bool
    var verticalCurve: UnitCurve? = nil
    @Environment(\.lyricResizeContext) private var resizeContext
    @Environment(\.lyricLineMoveDuration) private var lineMoveDuration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var staticHeight: CGFloat?
    @State private var previousSize: CGSize?
    @State private var motion: RowHeightMotion?

    func body(content: Content) -> some View {
        if reduceMotion || voiceOver {
            content
        } else {
            TimelineView(.animation(paused: motion == nil)) { context in
                content.fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        updateHeight(size)
                    }
                    .frame(height: motion?.height(at: context.date, curve: verticalCurve) ?? staticHeight,
                           alignment: .topLeading)
            }
            .onChange(of: resizeContext.isVisible) { _, visible in
                if !visible { settleHeight() }
            }
            .task(id: motion?.end) {
                guard let end = motion?.end else { return }
                do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
                guard let current = motion, current.end == end else { return }
                staticHeight = current.target
                motion = nil
            }
            .onDisappear {
                previousSize = nil
                staticHeight = nil
                motion = nil
            }
        }
    }

    private func updateHeight(_ size: CGSize) {
        let previous = previousSize
        previousSize = size
        guard resizeContext.isVisible else {
            settleHeight()
            return
        }
        guard size.height != previous?.height else { return }
        let isWrap = previous.map {
            (animateContentChanges || $0.width != size.width)
                && abs($0.height - size.height) >= wrapThreshold
        } ?? false
        let now = Date()
        let visible = motion?.height(at: now, curve: verticalCurve) ?? staticHeight ?? size.height

        if isWrap {
            if #available(iOS 18.0, *), stagesEnabled, resizeContext.clock != nil {
                let window = resizeContext.timing(at: now).heightWindow(expanding: size.height > visible)
                motion = RowHeightMotion(from: visible, target: size.height,
                                         start: max(now, window.lowerBound), end: window.upperBound)
            } else {
                let duration = resizeContext.clock == nil
                    ? 0.22 * lineMoveDuration / LyricReflowTiming.defaultMoveDuration
                    : LyricResizeTiming.slideDuration
                motion = RowHeightMotion(from: visible, target: size.height,
                                         start: now, end: now.addingTimeInterval(duration))
            }
        } else if let current = motion, now < current.end {
            motion = RowHeightMotion(from: visible, target: size.height, start: max(now, current.start), end: current.end)
        } else {
            settleHeight()
        }
    }

    private func settleHeight() {
        staticHeight = previousSize?.height
        motion = nil
    }
}

private struct RowHeightMotion {
    let from: CGFloat
    let target: CGFloat
    let start: Date
    let end: Date

    func height(at time: Date, curve: UnitCurve?) -> CGFloat {
        guard time > start else { return from }
        guard time < end else { return target }
        let phase = time.timeIntervalSince(start) / end.timeIntervalSince(start)
        let ease = CGFloat(curve?.value(at: phase) ?? (phase * phase * (3 - 2 * phase)))
        return from + (target - from) * ease
    }
}
