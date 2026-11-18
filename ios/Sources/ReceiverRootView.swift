import SwiftUI
import UIKit

/// The same receiver stays active while the settings sheet is open or while
/// an iPad window switches between full width and Split View.
@MainActor
struct ReceiverRootView: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("showLyrics") private var showLyrics = false
    @AppStorage("playerShowsProgress") private var showProgress = true
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("playerToolbarAlwaysVisible") private var toolbarAlwaysVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var showingSettings = false
    @State private var showingVolume = false
    @State private var toolbarRevealed = true
    @State private var toolbarHideTask: Task<Void, Never>?
    @State private var playerMode: PlayerPresentationLayout.Mode?

    private var hasTrack: Bool {
        guard let state = model.snapshot, state.controlsAvailable else { return false }
        return state.phase == .playing || state.phase == .paused || !state.trackId.isEmpty
            || !state.title.isEmpty || (state.durationMs ?? 0) > 0
    }

    private var trackKey: String { TrackIdentity(snapshot: model.snapshot).key }

    private var toolbarCanHide: Bool {
        hasTrack && !toolbarAlwaysVisible && !voiceOver && !showingVolume && !showingSettings
    }

    private var toolbarVisible: Bool { !toolbarCanHide || toolbarRevealed }

    private var displayAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.36)
    }

    private var lyricPanelTransition: AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(x: 0, y: 12))
    }

    var body: some View {
        GeometryReader { proxy in
            let headerGutter = PlayerPresentationLayout.horizontalInset(for: proxy.size.width)
            VStack(spacing: 0) {
                header.padding(.horizontal, headerGutter)
                GeometryReader { content in
                    if hasTrack {
                        let layout = PlayerPresentationLayout(
                            size: content.size,
                            showsLyrics: showLyrics,
                            accessibilitySize: dynamicTypeSize.isAccessibilitySize,
                            showsProgress: showProgress,
                            showsPlaybackControls: showPlaybackControls
                        )
                        ZStack {
                            playerContent(layout, height: content.size.height)
                        }
                        .animation(displayAnimation, value: layout.mode)
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
        }
        .preferredColorScheme(.dark)
        .tint(PlayerPalette.accent)
        .sheet(isPresented: $showingSettings) { ReceiverSettingsView(model: model) }
        .onChange(of: toolbarCanHide, initial: true) { _, _ in revealToolbar() }
        .onChange(of: hasTrack) { _, active in
            if !active { showingVolume = false }
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

    private enum PlayerSection { case player, lyrics }

    private func playerContent(_ layout: PlayerPresentationLayout, height: CGFloat) -> some View {
        let lyricsBesidePlayer = layout.mode == .artworkAndLyrics
        let controlsBesideCover = layout.mode == .artworkAndControls
        let playbackWidth = lyricsBesidePlayer ? layout.leadingWidth : layout.contentWidth
        let viewportHeight = max(0, height - layout.verticalInset * 2)
        let lyricSize = CGSize(
            width: lyricsBesidePlayer ? max(0, layout.contentWidth - layout.leadingWidth - layout.gap) : layout.contentWidth,
            height: lyricsBesidePlayer ? viewportHeight : layout.lyricsHeight
        )
        let panelLayout = lyricsBesidePlayer
            ? AnyLayout(HStackLayout(alignment: .center, spacing: layout.gap))
            : AnyLayout(VStackLayout(alignment: .center, spacing: 30))
        let controlsLayout = controlsBesideCover
            ? AnyLayout(HStackLayout(alignment: .center, spacing: layout.gap))
            : AnyLayout(VStackLayout(alignment: .center, spacing: lyricsBesidePlayer ? 22 : 24))

        return ScrollViewReader { reader in
            ScrollView {
                panelLayout {
                    controlsLayout {
                        cover(side: layout.coverSide)
                            .frame(width: controlsBesideCover ? layout.leadingWidth : nil)
                        playbackDetails
                            .frame(maxWidth: controlsBesideCover ? 420 : .infinity)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(width: playbackWidth)
                    .id(PlayerSection.player)

                    if showLyrics {
                        lyricsPane
                            .frame(width: lyricSize.width, height: lyricSize.height)
                            .animation(nil, value: lyricSize)
                            .id(PlayerSection.lyrics)
                            .transition(lyricPanelTransition)
                    }
                }
                .frame(width: layout.contentWidth)
                .frame(maxWidth: .infinity)
                .frame(minHeight: viewportHeight)
                .padding(.vertical, layout.verticalInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: layout.mode, initial: true) { previous, current in
                playerMode = current
                guard previous == .artworkAndLyrics, current == .stacked, showLyrics else { return }
                scrollPlayer(reader, towardLyrics: true)
            }
            .onChange(of: showLyrics) { _, shown in
                guard layout.mode == .stacked else { return }
                scrollPlayer(reader, towardLyrics: shown)
            }
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

    private var header: some View {
        HStack(spacing: 6) {
            if !hasTrack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FusionPlay").font(.headline.weight(.bold))
                    statusLabel.font(.caption)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if hasTrack {
                    headerButton(showLyrics ? "quote.bubble.fill" : "quote.bubble",
                                 label: showLyrics ? "隐藏歌词" : "显示歌词", selected: showLyrics) {
                        revealToolbar()
                        withAnimation(displayAnimation) { showLyrics.toggle() }
                    }
                    ReceiverVolumeControl(model: model, showingVolume: $showingVolume)
                }
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
                if let artwork = hasTrack && !reduceTransparency ? model.artwork : nil {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .blur(radius: 62)
                        .opacity(0.45)
                        .id(ObjectIdentifier(artwork))
                        .transition(.opacity)
                }
                LinearGradient(
                    colors: [PlayerPalette.background.opacity(0.12), PlayerPalette.background.opacity(0.80)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.34), value: model.artwork.map(ObjectIdentifier.init))
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

    private var playbackDetails: some View {
        VStack(alignment: .leading, spacing: 13) {
            PlayerTrackMetadataView(title: model.displayTitle, subtitle: model.displaySubtitle, trackKey: trackKey)
            if showProgress {
                ReceiverProgressView(model: model)
                    .tint(.white)
                    .transition(.opacity)
            }
            if showPlaybackControls {
                transport.transition(.opacity)
            }
            if !model.controlMessage.isEmpty {
                Text(model.controlMessage)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var transport: some View {
        let playing = model.snapshot?.phase == .playing
        return HStack(spacing: 0) {
            transportButton("backward.end.fill", label: "上一曲") { model.control(.previous) }
            transportButton(playing ? "pause.fill" : "play.fill", label: playing ? "暂停" : "播放", prominent: true) {
                model.togglePlayback()
            }
            transportButton("forward.end.fill", label: "下一曲") { model.control(.next) }
        }
        .frame(maxWidth: 326)
        .frame(maxWidth: .infinity)
        .disabled(!model.canControl)
        .opacity(model.canControl ? 1 : 0.45)
    }

    private func transportButton(_ image: String, label: LocalizedStringKey, prominent: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: prominent ? 27 : 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: prominent ? 62 : 46, height: prominent ? 62 : 46)
                .background(.white.opacity(prominent ? 0.14 : 0), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @AppStorage("staggerLyricMotion") private var staggerLyricMotion = true
    @AppStorage("lyricStaggerMilliseconds") private var lyricStaggerMilliseconds = LyricReflowTiming.defaultStaggerMilliseconds
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
    @State private var showsEmptyState = false
    @State private var viewportSize: CGSize?
    @State private var isSettlingSize = false
    @State private var followWave: LyricFollowWave?

    private var staggerSpan: TimeInterval {
        guard staggerLyricMotion, !reduceMotion, !voiceOver else { return 0 }
        return LyricReflowTiming.staggerSpan(milliseconds: lyricStaggerMilliseconds)
    }
    private var isCurrentTrack: Bool { TrackIdentity(snapshot: model.snapshot).key == trackKey }

    private static let viewport = "receiver.lyrics.viewport"
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
        .onChange(of: staggerSpan) { _, span in
            if span == 0 { followWave = nil }
        }
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
                viewportSize = nil
                isSettlingSize = false
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
        let bleed: CGFloat = allowsEffects ? 14 : 0
        let fontSize = min(36, max(26, size.width * 0.076)) * typeScale
        let topBlur: CGFloat = allowsEffects ? 3.5 : 0
        let bottomBlur: CGFloat = allowsEffects ? 10 : 0
        let timed = document.isTimed

        return ScrollViewReader { proxy in
            trackScroll(timed: timed) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: min(22, max(17, 17 + (size.width - 350) / 10))) {
                        ForEach(document.lines) { line in
                            lyricRow(line, activeID: activeID, timed: timed, fontSize: fontSize)
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
                    .padding(.horizontal, bleed)
                    .padding(.top, timed && !voiceOver ? max(12, size.height * 0.32) : 12)
                    .padding(.bottom, timed && !voiceOver ? max(16, size.height * 0.68) : 16)
                }
            }
            .coordinateSpace(name: Self.viewport)
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
                scroll(proxy, to: current, animated: previous != current, from: previous)
            }
            .task(id: size) {
                guard let previous = viewportSize else {
                    viewportSize = size
                    return
                }
                viewportSize = size
                guard previous != size else { return }
                isSettlingSize = true
                do { try await Task.sleep(for: .seconds(LyricReflowTiming.duration + staggerSpan + 0.05)) }
                catch { return }
                isSettlingSize = false
                let latest = model.lyrics
                let index = model.displayedPositionMs.flatMap { latest.activeLineIndex(at: $0) }
                scroll(proxy, to: index.map { latest.lines[$0].id }, animated: true)
            }
            .onChange(of: following) { _, active in
                if active { scroll(proxy, to: activeID, animated: true) }
            }
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
    private func lyricRow(_ line: LyricsLine, activeID: Int?, timed: Bool, fontSize: CGFloat) -> some View {
        let active = line.id == activeID
        let opacity: Double = {
            if !timed { return 0.88 }
            if active { return 1 }
            if contrast == .increased { return 0.74 }
            guard let activeID else { return line.id == 0 ? 0.72 : 0.42 }
            return abs(line.id - activeID) <= 1 ? 0.57 : 0.32
        }()
        let label = VStack(alignment: .leading, spacing: 6) {
            LyricReflowText(line.text.isEmpty ? "•••" : line.text, size: fontSize, weight: .bold, lineSpacing: 2)
            if let translation = line.translation, !translation.isEmpty {
                LyricReflowText(translation, size: fontSize * 0.60, weight: .semibold)
                    .opacity(0.78)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PlayerTextHeightMotion(
            wrapThreshold: fontSize * 0.45,
            stagesEnabled: line.text.utf8.count <= 1_024 && (line.translation?.utf8.count ?? 0) <= 1_024,
            animateContentChanges: false
        ))
        .foregroundStyle(.white)
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
                .buttonStyle(.plain)
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

    private func scroll(_ proxy: ScrollViewProxy, to id: Int?, animated: Bool, from previous: Int? = nil) {
        guard isCurrentTrack, following, !isSettlingSize, !dragging, !scrollInMotion, !voiceOver, let id else { return }
        let span = staggerSpan
        if animated, span > 0, let previous, (1...2).contains(abs(id - previous)) {
            followWave = LyricFollowWave(start: Date(), direction: id > previous ? 1 : -1, span: span)
        }
        withAnimation(animated && !reduceMotion ? .easeInOut(duration: LyricFollowWave.duration) : nil) {
            proxy.scrollTo(id, anchor: Self.followAnchor)
        }
    }
}

private struct LyricFollowWave {
    static let duration = 0.42
    let start: Date
    let direction: CGFloat
    let span: TimeInterval

    var end: Date { start.addingTimeInterval(Self.duration + span) }

    func offset(at time: Date, position: Double) -> CGFloat {
        let delay = LyricReflowTiming.staggerDelay(span: span, position: position)
        let elapsed = time.timeIntervalSince(start)
        func eased(_ time: TimeInterval) -> Double {
            let phase = min(1, max(0, time / Self.duration))
            return phase * phase * (3 - 2 * phase)
        }
        return direction * 36 * CGFloat(eased(elapsed) - eased(elapsed - delay))
    }
}

private struct LyricRowStagger: ViewModifier {
    private static let steps = 32

    let span: TimeInterval
    let viewport: String
    let viewportHeight: CGFloat
    let wave: LyricFollowWave?

    @State private var rank = 0

    func body(content: Content) -> some View {
        let position = Double(rank) / Double(Self.steps)
        let delay = LyricReflowTiming.staggerDelay(span: span, position: position)
        let activeWave = span > 0 ? wave : nil
        TimelineView(.animation(paused: activeWave == nil)) { context in
            content
                .environment(\.lyricMotionDelay, delay)
                .offset(y: activeWave?.offset(at: context.date, position: position) ?? 0)
        }
        .onGeometryChange(for: Int.self) { geometry in
            guard span > 0, viewportHeight.isFinite, viewportHeight > 0 else { return 0 }
            let center = geometry.frame(in: .named(viewport)).midY
            guard center.isFinite else { return 0 }
            let position = min(1, max(0, center / viewportHeight))
            return Int((position * CGFloat(Self.steps)).rounded())
        } action: { rank = $0 }
    }
}

struct PlayerTextHeightMotion: ViewModifier {
    let wrapThreshold: CGFloat
    let stagesEnabled: Bool
    let animateContentChanges: Bool
    @Environment(\.lyricMotionDelay) private var delay
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
                    .frame(height: motion?.height(at: context.date) ?? staticHeight, alignment: .topLeading)
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
        guard size.height != previous?.height else { return }
        let isWrap = previous.map {
            (animateContentChanges || $0.width != size.width)
                && abs($0.height - size.height) >= wrapThreshold
        } ?? false
        let now = Date()
        let visible = motion?.height(at: now) ?? staticHeight ?? size.height

        if isWrap {
            if #available(iOS 18.0, *), stagesEnabled {
                motion = RowHeightMotion(
                    from: visible, target: size.height,
                    start: now.addingTimeInterval(delay + LyricReflowTiming.duration * LyricReflowTiming.rowStart),
                    end: now.addingTimeInterval(delay + LyricReflowTiming.duration * LyricReflowTiming.rowEnd)
                )
            } else {
                motion = RowHeightMotion(from: visible, target: size.height, start: now, end: now.addingTimeInterval(0.22))
            }
        } else if let current = motion, now < current.end {
            motion = RowHeightMotion(from: visible, target: size.height, start: max(now, current.start), end: current.end)
        } else {
            staticHeight = size.height
            motion = nil
        }
    }
}

private struct RowHeightMotion {
    let from: CGFloat
    let target: CGFloat
    let start: Date
    let end: Date

    func height(at time: Date) -> CGFloat {
        guard time > start else { return from }
        guard time < end else { return target }
        let phase = time.timeIntervalSince(start) / end.timeIntervalSince(start)
        let ease = CGFloat(phase * phase * (3 - 2 * phase))
        return from + (target - from) * ease
    }
}

@MainActor
private struct ReceiverSettingsView: View {
    @ObservedObject var model: ReceiverModel
    @AppStorage("autoStartReceiver") private var autoStartReceiver = true
    @AppStorage("playerShowsProgress") private var showProgress = true
    @AppStorage("playerShowsTransport") private var showPlaybackControls = true
    @AppStorage("showLyrics") private var showLyrics = false
    @AppStorage("uiCorrectLyricTitles") private var correctLyricTitles = false
    @AppStorage("playerToolbarAlwaysVisible") private var toolbarAlwaysVisible = false
    @AppStorage("staggerLyricMotion") private var staggerLyricMotion = true
    @AppStorage("lyricStaggerMilliseconds") private var lyricStaggerMilliseconds = LyricReflowTiming.defaultStaggerMilliseconds
    @AppStorage("wrapPlayerMetadata") private var wrapPlayerMetadata = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingName: Bool
    @State private var draftName = ""

    private var validName: Bool {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != model.name && trimmed.utf8.count <= 63
            && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("接收状态", value: model.statusText)
                    Toggle("打开 App 时自动接收", isOn: $autoStartReceiver)
                    if model.wantsReceiving {
                        Button("停止接收", role: .destructive) { model.stop() }
                            .disabled(model.busy)
                    } else {
                        Button("开始接收") { model.start() }
                            .disabled(model.busy)
                    }
                    if !model.error.isEmpty {
                        Text(model.error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                Section("设备名称") {
                    TextField("妙播列表显示的名称", text: $draftName)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($editingName)
                        .onSubmit(saveName)
                    Button("保存名称", action: saveName)
                        .disabled(!model.initialized || !validName || model.busy)
                }
                ReceiverSyncSettings(model: model)
                Section("播放显示") {
                    Toggle("显示进度与时间", isOn: $showProgress)
                    Toggle("显示播放控制", isOn: $showPlaybackControls)
                    Toggle("允许歌名和艺人信息换行", isOn: $wrapPlayerMetadata)
                    Toggle("显示歌词", isOn: $showLyrics)
                    Toggle("歌词交错动效", isOn: $staggerLyricMotion)
                    if staggerLyricMotion {
                        lyricStaggerControl
                    }
                    Toggle("始终显示顶部按钮", isOn: $toolbarAlwaysVisible)
                    Toggle("修正歌词标题", isOn: $correctLyricTitles)
                        .onChange(of: correctLyricTitles) { _, _ in model.refreshDisplayPresentation() }
                }
            }
            .navigationTitle("接收设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { draftName = model.name }
            .onChange(of: model.name) { _, name in if !editingName { draftName = name } }
        }
    }

    private var lyricStaggerControl: some View {
        let range = LyricReflowTiming.staggerRange
        let millis = LyricReflowTiming.clampedStaggerMilliseconds(lyricStaggerMilliseconds)
        let value = Text(verbatim: "\(millis) ms").monospacedDigit()

        return VStack(alignment: .leading, spacing: 7) {
            LabeledContent("交错时间跨度") { value }
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { Double(LyricReflowTiming.clampedStaggerMilliseconds(lyricStaggerMilliseconds)) },
                    set: { lyricStaggerMilliseconds = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(LyricReflowTiming.staggerStep)
            )
            .accessibilityLabel("交错时间跨度")
            .accessibilityValue(value)
            .accessibilityHint("可见歌词从上到下的最大动效时差")
        }
    }

    private func saveName() {
        guard model.initialized, validName, !model.busy else { return }
        editingName = false
        model.saveName(draftName.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
