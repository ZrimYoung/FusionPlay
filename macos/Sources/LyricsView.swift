import AppKit
import SwiftUI

/// A source-only lyric presentation. It never downloads or persists lyrics.
struct LyricsView: View {
    @Environment(\.appTypography) private var typography
    let document: LyricsDocument
    let positionMs: UInt64?
    let loading: Bool
    let connected: Bool
    let compact: Bool
    let canSeek: Bool
    var presentationActive = true
    var geometryInteractionActive = false
    let seek: (UInt64) -> Void
#if FUSIONPLAY_UI_CHECKS
    var checkReduceMotion: Bool? = nil
    var checkVoiceOver: Bool? = nil
#endif

    @AppStorage("appLanguage") private var language = "zh-Hans"
    @AppStorage("staggerLyricMotion") private var staggerLyricMotion = LyricsStaggerTiming.defaultEnabled
    @AppStorage("lyricStaggerMilliseconds") private var lyricStaggerMilliseconds = LyricsStaggerTiming.defaultMilliseconds
    @AppStorage("lyricLineMoveMilliseconds") private var lyricLineMoveMilliseconds = LyricsStaggerTiming.defaultMoveMilliseconds
    @AppStorage("lyricsFontScalePercent") private var lyricsFontScalePercent = LyricsTypography.defaultScalePercent
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var systemVoiceOver
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var browsing = false
    @GestureState private var dragging = false
    @State private var browsingRevision = 0
    @State private var followRequestRevision: Int?
    @State private var followPosition = LyricsFollowPosition()
    @State private var liveResizing = false
    @State private var viewportSettling = false
    @State private var viewportRevision = 0
    @State private var viewportFollowRequest: Int?
    @State private var presentationRevision = 0
    @State private var presentationFollowRequest: Int?
    @State private var needsPresentationFollow = false
    @State private var followWave: LyricsFollowWave?
    @StateObject private var viewportAnchor = LyricsViewportAnchor()

    private var resizing: Bool { liveResizing || geometryInteractionActive }

    private var lineMoveDuration: TimeInterval {
        LyricsStaggerTiming.moveDuration(milliseconds: lyricLineMoveMilliseconds)
    }
    private var staggerSpan: TimeInterval {
        guard staggerLyricMotion, !reduceMotion, !voiceOver else { return 0 }
        return LyricsStaggerTiming.span(milliseconds: lyricStaggerMilliseconds)
    }

    private var reduceMotion: Bool {
#if FUSIONPLAY_UI_CHECKS
        return checkReduceMotion ?? systemReduceMotion
#else
        return systemReduceMotion
#endif
    }
    private var voiceOver: Bool {
#if FUSIONPLAY_UI_CHECKS
        return checkVoiceOver ?? systemVoiceOver
#else
        return systemVoiceOver
#endif
    }

    private var activeIndex: Int? {
        guard let position = followPosition.current(positionMs, connected: connected) else { return nil }
        return document.activeLineIndex(at: position)
    }
    private var activeID: Int? {
        activeIndex.map { document.lines[$0].id }
    }

    var body: some View {
        GeometryReader { geometry in
            let topBand = max(12, geometry.size.height * 0.30)
            let bottomBand = max(12, geometry.size.height * 0.45)
            let maximumBlur: CGFloat = reduceTransparency || contrast == .increased ? 0 : (compact ? 8 : 12)
            let maximumTopBlur: CGFloat = reduceTransparency || contrast == .increased ? 0 : (compact ? 2.5 : 4)
            // Preserve the original text inset while giving the blur kernel
            // space outside both horizontal edges of the content column.
            let horizontalBleed: CGFloat = compact ? 16 : 24
            if document.lines.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: LyricsRowMetrics(width: geometry.size.width).rowSpacing) {
                            ForEach(document.lines.indices, id: \.self) { index in
                                let line = document.lines[index]
                                lyricRow(line, index: index, width: geometry.size.width)
                                    .background {
                                        LyricsViewportRowProbe(id: line.id, anchor: viewportAnchor)
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                                    .modifier(LyricsResizeVisibility(viewport: "fusionplay.lyrics.viewport",
                                        viewportSize: geometry.size, presentationActive: presentationActive))
                                    .modifier(LyricsRowStagger(span: staggerSpan, viewport: "fusionplay.lyrics.viewport",
                                                              viewportHeight: geometry.size.height, wave: followWave))
                                    .visualEffect { [height = geometry.size.height, maximumBlur, maximumTopBlur,
                                                    current = line.id == activeID] content, row in
                                        content.blur(radius: Self.edgeBlurRadius(
                                            frame: row.frame(in: .named("fusionplay.lyrics.viewport")),
                                            viewportHeight: height, topMaximum: maximumTopBlur,
                                            bottomMaximum: maximumBlur,
                                            current: current))
                                    }
                                    .id(line.id)
                            }
                        }
                        // Give both endpoints enough room to reach the upper
                        // reading position. Untimed text starts beyond the blur
                        // band without being programmatically pulled to the edge.
                        .padding(.horizontal, horizontalBleed + 3)
                        .padding(.top, document.isTimed ? max(14, geometry.size.height * 0.32) : topBand + 14)
                        .padding(.bottom, document.isTimed ? max(14, geometry.size.height * 0.68) : bottomBand + 14)
                    }
                    .coordinateSpace(name: "fusionplay.lyrics.viewport")
                    .scrollClipDisabled()
                    .scrollIndicators(.hidden)
                    .background {
                        LyricsScrollActivity(anchor: viewportAnchor, activeID: activeID,
                                             browsing: browsing, anchoringEnabled: !voiceOver && (presentationActive || browsing),
                                             geometryInteractionActive: geometryInteractionActive,
                                             onScroll: { userBeganBrowsing() }, onLiveResize: { resizing in
                            guard liveResizing != resizing else { return }
                            liveResizing = resizing
                            viewportChanged()
                        })
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 6)
                        .updating($dragging) { _, dragging, _ in dragging = true }
                        .onChanged { _ in userBeganBrowsing() })
                    .onChange(of: dragging) { _, dragging in
                        if !dragging && browsing { userBeganBrowsing() }
                    }
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.09),
                        .init(color: .black, location: 0.91),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .onAppear {
                        DispatchQueue.main.async { follow(proxy, animated: false, reason: "appear") }
                    }
                    .onChange(of: activeID) { previous, _ in
                        // VoiceOver owns its reading position; do not scroll its
                        // focused line away when playback advances.
                        if !browsing && !dragging && !voiceOver && !resizing && !viewportSettling {
                            follow(proxy, animated: true, reason: "playback", previousID: previous)
                        }
                    }
                    .onChange(of: presentationActive) { _, active in
                        presentationRevision &+= 1
                        presentationFollowRequest = nil
                        needsPresentationFollow = active && !browsing && !dragging && !voiceOver
                        // An offscreen pane's old visible row is not a reading
                        // anchor for the page the user is just opening.
                        if !browsing { viewportAnchor.cancel() }
                        if !active {
                            viewportSettling = false
                            viewportRevision &+= 1
                            viewportFollowRequest = nil
                            clearFollowWave()
                        }
                    }
                    .task(id: presentationRevision) {
                        guard presentationRevision > 0, presentationActive, needsPresentationFollow else { return }
                        // The pager changes its transform without changing this
                        // viewport's size. Wait for that motion and lazy rows.
                        do { try await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 300)) }
                        catch { return }
                        let deadline = Date().addingTimeInterval(1.6)
                        while (viewportSettling || Date().timeIntervalSince(viewportAnchor.lastGeometryChange) < 0.1), Date() < deadline {
                            do { try await Task.sleep(for: .milliseconds(20)) }
                            catch { return }
                        }
                        guard !Task.isCancelled, presentationActive, !resizing else { return }
                        presentationFollowRequest = presentationRevision
                    }
                    .onChange(of: presentationFollowRequest) { _, revision in
                        guard revision == presentationRevision, presentationActive, needsPresentationFollow,
                              !viewportSettling, !resizing else { return }
                        needsPresentationFollow = false
                        viewportAnchor.cancel()
                        follow(proxy, animated: false, reason: "presentation")
                    }
                    .onChange(of: geometryInteractionActive) { _, _ in viewportChanged() }
                    .onChange(of: geometry.size) { _, _ in viewportChanged() }
                    .task(id: viewportRevision) {
                        guard viewportRevision > 0, presentationActive, !resizing else { return }
                        // Let the final word reflow and row-height move finish before
                        // restoring the reading anchor, as on the iPad player.
                        let settle = reduceMotion ? 0.18 : LyricsReflowText.transitionDuration + staggerSpan + 0.05
                        do { try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000)) }
                        catch { return }
                        // A newly realized lazy row can arrive just after the
                        // text renderer's deadline. Release only after a short
                        // quiet period, with a bound for continuously playing text.
                        let quietLimit = Date().addingTimeInterval(0.4)
                        while Date().timeIntervalSince(viewportAnchor.lastGeometryChange) < 0.1, Date() < quietLimit {
                            do { try await Task.sleep(for: .milliseconds(20)) }
                            catch { return }
                        }
                        guard !Task.isCancelled, presentationActive, !resizing else { return }
                        viewportSettling = false
                        // Trigger a fresh view callback after the quiet period;
                        // an async task's captured playback position can be old.
                        viewportFollowRequest = viewportRevision
                    }
                    .onChange(of: viewportFollowRequest) { _, revision in
                        guard revision == viewportRevision, presentationActive, !viewportSettling, !resizing else { return }
                        let presentationFollow = needsPresentationFollow
                        let preserved: Bool
                        if presentationFollow { viewportAnchor.cancel(); preserved = false }
                        else { preserved = viewportAnchor.finish(activeID: activeID) }
#if FUSIONPLAY_UI_CHECKS
                        LyricsViewCheckEvents.anchorFinished?(activeID, preserved)
#endif
                        if browsing { browsingRevision &+= 1 }
                        guard document.isTimed, !browsing, !dragging, !voiceOver else { return }
                        if presentationFollow {
                            needsPresentationFollow = false
                            follow(proxy, animated: false, reason: "presentation")
                        } else if !preserved { follow(proxy, animated: true, reason: "viewport") }
                    }
                    .onChange(of: document) { _, _ in
                        DispatchQueue.main.async {
                            if !resizing && !viewportSettling { follow(proxy, animated: false, reason: "document") }
                        }
                    }
                    .onChange(of: followRequestRevision) { _, revision in
                        guard let revision, revision == browsingRevision, !browsing, !voiceOver else { return }
                        // Resolve the target from the latest playback value,
                        // not the view captured before the inactivity delay.
                        guard !resizing && !viewportSettling else { return }
                        follow(proxy, animated: true, reason: "resume")
                    }
                    .task(id: browsingRevision) {
                        guard browsing else { return }
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                        catch { return }
                        // A held drag may be stationary for longer than the
                        // delay. Its end starts a fresh inactivity countdown.
                        guard !Task.isCancelled, !dragging, !resizing, !viewportSettling else { return }
                        browsing = false
                        followRequestRevision = browsingRevision
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("歌词"))
                    .padding(.horizontal, -horizontalBleed)
                }
            }
        }
        .onAppear { followPosition.observe(positionMs, connected: connected) }
        .task(id: followWave?.start) {
            guard let wave = followWave else { return }
            do { try await Task.sleep(nanoseconds: UInt64(max(0, wave.end.timeIntervalSinceNow) * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, followWave?.start == wave.start else { return }
            clearFollowWave()
        }
        .onChange(of: staggerSpan) { _, _ in clearFollowWave() }
        .onChange(of: lineMoveDuration) { _, _ in clearFollowWave() }
        .onChange(of: lyricsFontScalePercent) { _, _ in viewportChanged() }
        .onChange(of: positionMs) { _, position in
            followPosition.observe(position, connected: connected)
        }
        .onChange(of: connected) { _, connected in
            followPosition.observe(positionMs, connected: connected)
            if !connected { resetBrowsing() }
        }
        .onDisappear {
            resetBrowsing()
            viewportAnchor.disconnect()
            liveResizing = false; viewportSettling = false
            viewportRevision &+= 1; viewportFollowRequest = nil
        }
        // Keep the reset outside the empty/nonempty branch: switching tracks
        // briefly clears the document while the next LRC is parsed.
        .onChange(of: document) { _, _ in resetBrowsing(); clearFollowWave() }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small).tint(.white.opacity(0.7))
                Text(L("正在载入歌词…"))
                    .font(typography.font(size: compact ? 13 : 15))
            } else {
                Image(systemName: connected ? "quote.bubble" : "music.note")
                    .font(.system(size: compact ? 23 : 28, weight: .light))
                    .padding(.bottom, 3)
                Text(L(connected ? "暂无歌词" : "等待你的音乐"))
                    .font(typography.font(size: compact ? 13 : 15, weight: .medium))
                if connected {
                    Text(L("歌词由手机提供"))
                        .font(typography.font(size: compact ? 11 : 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .foregroundStyle(.white.opacity(0.65))
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func lyricRow(_ line: LyricsLine, index: Int, width: CGFloat) -> some View {
        if let time = line.timeMs {
            // Keep the row subtree stable while a seek command temporarily
            // disables controls; changing Button to text can reset native scroll.
            Button {
                guard canSeek else { return }
                resetBrowsing()
                seek(time)
            } label: { rowContent(line, index: index, width: width) }
                .buttonStyle(LyricsRowButtonStyle())
                .disabled(!canSeek)
                .accessibilityHint(canSeek ? L("跳转到此歌词") : "")
                .accessibilityValue(index == activeIndex ? L("当前歌词") : "")
        } else {
            rowContent(line, index: index, width: width)
                .accessibilityElement(children: .combine)
                .accessibilityValue(index == activeIndex ? L("当前歌词") : "")
        }
    }

    private func rowContent(_ line: LyricsLine, index: Int, width: CGFloat) -> some View {
        let active = index == activeIndex
        let metrics = LyricsRowMetrics(width: width)
        let scale = LyricsTypography.scale(percent: lyricsFontScalePercent)
        let size = metrics.fontSize * scale
        let translationSize = size * 0.60
        let primaryFont = typography.nsFont(size: size, weight: .bold)
        let translationFont = typography.nsFont(size: translationSize, weight: .semibold)
        let identity = LyricsRowContentIdentity(text: line.text, translation: line.translation,
            primaryFace: primaryFont.fontName, primaryTraits: primaryFont.fontDescriptor.symbolicTraits.rawValue,
            translationFace: translationFont.fontName, translationTraits: translationFont.fontDescriptor.symbolicTraits.rawValue)
        let opacity: Double = {
            if !document.isTimed { return 0.88 }
            if active { return 1 }
            if contrast == .increased { return 0.74 }
            guard let activeIndex else { return index == 0 ? 0.72 : 0.4 }
            return abs(index - activeIndex) <= 1 ? 0.56 : 0.3
        }()
        return VStack(alignment: .leading, spacing: metrics.translationSpacing) {
            if line.text.isEmpty {
                Text("•••")
                    .font(typography.font(size: size, weight: .semibold))
                    .tracking(5)
                    .accessibilityLabel(L("歌词间隔"))
            } else {
                LyricsReflowText(text: line.text, font: primaryFont,
                                 lineSpacing: 2, reduceMotion: reduceMotion,
                                 width: max(1, width - 6))
                    .environment(\.lyricsResizeParticipant, .primary)
            }
            if let translation = line.translation, !translation.isEmpty {
                LyricsReflowText(text: translation,
                                 font: translationFont,
                                 lineSpacing: 0, reduceMotion: reduceMotion, width: max(1, width - 6))
                    .opacity(0.78)
                    .environment(\.lyricsResizeParticipant, .translation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(LyricsRowHeightMotion(identity: identity, wrapThreshold: size * 0.45,
            stagesEnabled: line.text.utf8.count <= 1_024 && (line.translation?.utf8.count ?? 0) <= 1_024))
        .padding(.vertical, metrics.verticalPadding)
        .foregroundStyle(.white)
        .opacity(opacity)
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: active)
    }

    /// A visual-only transform: scrolling updates geometry without changing
    /// layout, row identity, or SwiftUI state. Blur grows smoothly at both edges.
    nonisolated private static func edgeBlurRadius(frame: CGRect, viewportHeight: CGFloat,
                                                  topMaximum: CGFloat, bottomMaximum: CGFloat,
                                                  current: Bool) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        if current && frame.height > viewportHeight * 0.6 { return 0 }
        let topBand = max(12, viewportHeight * 0.30)
        let bottomBand = max(12, viewportHeight * 0.45)
        let topAmount = 1 - min(1, max(0, frame.midY / topBand))
        let bottomDistance = viewportHeight - frame.midY
        let bottomAmount = 1 - min(1, max(0, bottomDistance / bottomBand))
        let topBlur = topMaximum * topAmount * topAmount * (3 - 2 * topAmount)
        let bottomBlur = bottomMaximum * bottomAmount * bottomAmount * (3 - 2 * bottomAmount)
        return max(topBlur, bottomBlur)
    }

    private func viewportChanged() {
        guard presentationActive else {
            if !browsing { viewportAnchor.cancel() }
            return
        }
        viewportAnchor.configure(activeID: activeID, browsing: browsing, enabled: !voiceOver,
                                 synchronousGeometry: geometryInteractionActive)
        viewportAnchor.beginIfNeeded(retryWhenReady: true)
        if !viewportSettling {
            if let wave = followWave {
                followWave = LyricsFollowWave(start: Date(), direction: 0, span: 0,
                                               duration: 0.18, previous: wave)
            }
        }
        viewportSettling = true
        viewportRevision &+= 1
    }
    private func userBeganBrowsing() {
        viewportAnchor.cancel()
        guard document.isTimed, connected else { return }
        clearFollowWave()
        browsing = true
        browsingRevision &+= 1
    }
    private func resetBrowsing() {
        viewportAnchor.cancel()
        clearFollowWave()
        browsing = false
        browsingRevision &+= 1
        followRequestRevision = nil
    }
    private func clearFollowWave() {
        guard followWave != nil else { return }
        followWave = nil
#if FUSIONPLAY_UI_CHECKS
        LyricsViewCheckEvents.wave?(nil)
#endif
    }
    private func follow(_ proxy: ScrollViewProxy, animated: Bool, reason: String,
                        previousID: Int? = nil) {
        // Respect native browsing and accessibility even for asynchronous
        // appear/document callbacks captured before the activity began.
        guard presentationActive, !browsing, !dragging, !voiceOver, !resizing, !viewportSettling else { return }
        // Unknown progress is not an instruction to jump to the first line.
        guard document.isTimed, followPosition.current(positionMs, connected: connected) != nil else { return }
        guard let id = activeID ?? document.lines.first?.id else { return }
        let anchor = UnitPoint(x: 0.5, y: 0.32)
        if animated, staggerSpan > 0, let previousID, (1...2).contains(abs(id - previousID)) {
            let wave = LyricsFollowWave(start: Date(), direction: id > previousID ? 1 : -1, span: staggerSpan,
                                        duration: lineMoveDuration, previous: followWave)
            followWave = wave
#if FUSIONPLAY_UI_CHECKS
            LyricsViewCheckEvents.wave?(wave)
#endif
        } else { clearFollowWave() }
#if FUSIONPLAY_UI_CHECKS
        LyricsViewCheckEvents.follow?(reason, id, animated && !reduceMotion)
#endif
        if animated && !reduceMotion {
            withAnimation(.timingCurve(LyricsStaggerTiming.verticalMove, duration: lineMoveDuration)) {
                proxy.scrollTo(id, anchor: anchor)
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: anchor) }
        }
    }
}

#if FUSIONPLAY_UI_CHECKS
@MainActor enum LyricsViewCheckEvents {
    static var follow: ((String, Int, Bool) -> Void)?
    static var wave: ((LyricsFollowWave?) -> Void)?
    static var anchorFinished: ((Int?, Bool) -> Void)?
}

typealias LyricsRowGeometryCheckView = LyricsViewportRowView
#endif

#if FUSIONPLAY_UI_CHECKS
protocol LyricsActivityCheckDriving {
    func beginBrowsingForCheck()
}
#endif

private struct LyricsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Observe only wheel events inside this lyric scroll region. Returning the
/// original event preserves native scrolling and does not capture input.
private struct LyricsScrollActivity: NSViewRepresentable {
    let anchor: LyricsViewportAnchor
    let activeID: Int?
    let browsing: Bool
    let anchoringEnabled: Bool
    let geometryInteractionActive: Bool
    let onScroll: () -> Void
    let onLiveResize: (Bool) -> Void
    func makeNSView(context: Context) -> ActivityView {
        let view = ActivityView()
        view.anchor = anchor
        anchor.configure(activeID: activeID, browsing: browsing, enabled: anchoringEnabled,
                         synchronousGeometry: geometryInteractionActive)
        view.onScroll = onScroll
        view.onLiveResize = onLiveResize
        return view
    }
    func updateNSView(_ view: ActivityView, context: Context) {
        view.anchor = anchor
        anchor.configure(activeID: activeID, browsing: browsing, enabled: anchoringEnabled,
                         synchronousGeometry: geometryInteractionActive)
        view.onScroll = onScroll; view.onLiveResize = onLiveResize
        view.bindScrollView()
    }
    static func dismantleNSView(_ view: ActivityView, coordinator: ()) { view.disconnect() }

    final class ActivityView: NSView {
        weak var anchor: LyricsViewportAnchor?
        var onScroll: (() -> Void)?
        var onLiveResize: ((Bool) -> Void)?
        private var monitor: Any?
        private var resizeObservers: [NSObjectProtocol] = []
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disconnect()
            guard let window else { return }
            bindScrollView()
            // A compact/wide layout can attach midway through a native drag,
            // after willStartLiveResize has already been delivered.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.window === window else { return }
                self.onLiveResize?(window?.inLiveResize ?? false)
            }
            for (name, resizing) in [(NSWindow.willStartLiveResizeNotification, true),
                                     (NSWindow.didEndLiveResizeNotification, false)] {
                let token = NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.onLiveResize?(resizing) }
                }
                resizeObservers.append(token)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 ||
                        !event.phase.isEmpty || !event.momentumPhase.isEmpty else { return event }
                self.onScroll?()
                return event
            }
        }
        override func layout() { super.layout(); bindScrollView() }
        override func setFrameSize(_ newSize: NSSize) {
            if frame.width > 0, frame.height > 0,
               abs(frame.width - newSize.width) > 0.5 || abs(frame.height - newSize.height) > 0.5 {
                anchor?.beginIfNeeded()
            }
            super.setFrameSize(newSize)
            bindScrollView()
        }
        func bindScrollView() {
            guard let root = window?.contentView, bounds.width > 0 else { return }
            let scope = convert(bounds, to: nil)
            func scrolls(_ view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            let selected = scrolls(root).filter {
                // The persistent playback canvas has its own explicit native
                // role. It can overlap this viewport and be taller than lyrics.
                guard $0.identifier?.rawValue != "fusionplay.player.playback-scroll" else { return false }
                let overlap = $0.convert($0.bounds, to: nil).intersection(scope)
                return !overlap.isNull && overlap.width > scope.width * 0.7 && overlap.height > 40
            }.max { $0.bounds.height < $1.bounds.height }
            if let selected { anchor?.attach(selected, owner: self) }
        }
        func disconnect() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            resizeObservers.forEach(NotificationCenter.default.removeObserver)
            resizeObservers.removeAll()
            anchor?.detach(owner: self)
        }
        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            resizeObservers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

#if FUSIONPLAY_UI_CHECKS
extension LyricsScrollActivity.ActivityView: LyricsActivityCheckDriving {
    func beginBrowsingForCheck() { onScroll?() }
}
#endif


/// Typography depends on the lyric viewport, not the outer 600pt mode switch.
/// Keep the supported 20...34pt range and apply the user's scale separately.
struct LyricsRowMetrics {
    let fontSize: CGFloat
    let translationSpacing: CGFloat
    let rowSpacing: CGFloat
    let verticalPadding: CGFloat
    init(width: CGFloat) {
        let width = width.isFinite ? max(1, width) : 260
        let progress = min(1, max(0, (width - 260) / 280))
        fontSize = min(34, max(20, width * 0.075))
        translationSpacing = 5 + 2 * progress
        rowSpacing = 12 + 8 * progress
        verticalPadding = 3 + 2 * progress
    }
}

struct LyricsRowContentIdentity: Equatable {
    let text: String
    let translation: String?
    var primaryFace = ""
    var primaryTraits: UInt32 = 0
    var translationFace = ""
    var translationTraits: UInt32 = 0
}

struct LyricsRowMeasurement: Equatable {
    let identity: LyricsRowContentIdentity
    let size: CGSize
}

/// One height owner for the original and translation, matching the iPad row.
/// It measures native content without adding another text Layout/sizeThatFits.
struct LyricsRowHeightCoordinator {
    struct Motion {
        let from: CGFloat
        let target: CGFloat
        let start: Date
        let end: Date
        func height(at date: Date) -> CGFloat {
            guard date > start else { return from }
            guard date < end else { return target }
            let phase = date.timeIntervalSince(start) / end.timeIntervalSince(start)
            return from + (target - from) * CGFloat(LyricsStaggerTiming.verticalMove.value(at: phase))
        }
    }
    private(set) var previous: LyricsRowMeasurement?
    private(set) var staticHeight: CGFloat?
    private(set) var motion: Motion?

    func height(for identity: LyricsRowContentIdentity, at date: Date) -> CGFloat? {
        guard previous?.identity == identity else { return nil }
        return motion?.height(at: date) ?? staticHeight
    }

    mutating func observe(_ measurement: LyricsRowMeasurement, at date: Date,
                          delay: TimeInterval, wrapThreshold: CGFloat,
                          timingStart: Date? = nil, isVisible: Bool = true,
                          previousGeometry: LyricsRowMeasurement? = nil,
                          phaseSnapshot: LyricsResizePhaseSnapshot? = nil) {
        guard measurement.size.width.isFinite, measurement.size.height.isFinite,
              measurement.size.width > 0, measurement.size.height >= 0 else { return }
        let prior = previousGeometry ?? previous
        previous = measurement
        guard isVisible, let prior, prior.identity == measurement.identity else {
            staticHeight = measurement.size.height; motion = nil
            return
        }
        guard prior.size.height != measurement.size.height else { return }
        let visible = motion?.height(at: date) ?? staticHeight ?? prior.size.height
        // Native width and intrinsic height can arrive in separate deliveries.
        // Its real word phase is authoritative even if the width-only delivery
        // already updated the cache before the new height arrived.
        let significantHeightChange = abs(prior.size.height - measurement.size.height) >= wrapThreshold
        let hasWordPhase = phaseSnapshot?.phases.contains { $0.timing.end > date } ?? false
        let wraps = significantHeightChange && (prior.size.width != measurement.size.width || hasWordPhase)
        if wraps, let window = phaseSnapshot?.heightWindow(expanding: measurement.size.height > visible, at: date) {
            motion = Motion(from: visible, target: measurement.size.height,
                            start: window.lowerBound, end: window.upperBound)
        } else if wraps, phaseSnapshot != nil, let current = motion, date < current.end {
            motion = Motion(from: visible, target: measurement.size.height,
                            start: max(date, current.start), end: current.end)
        } else if wraps {
            let start = timingStart ?? date.addingTimeInterval(LyricsStaggerTiming.clampSpan(delay))
            motion = Motion(from: visible, target: measurement.size.height,
                start: start.addingTimeInterval(LyricsNativeMotionTiming.duration * LyricsNativeMotionTiming.rowStart),
                end: start.addingTimeInterval(LyricsNativeMotionTiming.duration * LyricsNativeMotionTiming.rowEnd))
        } else if let current = motion, date < current.end {
            motion = Motion(from: visible, target: measurement.size.height,
                            start: max(date, current.start), end: current.end)
        } else {
            staticHeight = measurement.size.height; motion = nil
        }
    }

    mutating func settle() {
        staticHeight = previous?.size.height; motion = nil
    }

    mutating func finish(endingAt end: Date) {
        guard let current = motion, current.end == end else { return }
        staticHeight = current.target; motion = nil
    }
}

@MainActor struct LyricsRowHeightMotion: ViewModifier {
    let identity: LyricsRowContentIdentity
    let wrapThreshold: CGFloat
    let stagesEnabled: Bool
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
    var checkReduceMotion: Bool? = nil
    var checkVoiceOver: Bool? = nil
#endif
    @Environment(\.lyricsRowMotionDelay) private var delay
    @Environment(\.lyricsResizeContext) private var resizeContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var coordinator = LyricsRowHeightCoordinator()
    @State private var measurements = LyricsRowMeasurementCache()

    private var enabled: Bool {
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
        guard stagesEnabled, !(checkReduceMotion ?? reduceMotion), !(checkVoiceOver ?? voiceOver) else { return false }
#else
        guard stagesEnabled, !reduceMotion, !voiceOver else { return false }
#endif
#if compiler(>=6.0)
        if #available(macOS 15.0, *) {
#if FUSIONPLAY_UI_CHECKS
            return !LyricsReflowTextCheckEvents.forceLegacyRenderer
#else
            return true
#endif
        }
#endif
        return false
    }

    @ViewBuilder func body(content: Content) -> some View {
#if compiler(>=6.0)
        if #available(macOS 15.0, *), enabled { nativeBody(content) }
        else { content }
#else
        content
#endif
    }

#if compiler(>=6.0)
    @available(macOS 15.0, *)
    private func nativeBody(_ content: Content) -> some View {
        let currentIdentity = identity
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: coordinator.motion == nil || !resizeContext.isVisible)) { context in
            content.environment(\.lyricsHeightManagedByRow, true)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: LyricsRowMeasurement.self) { [currentIdentity] geometry in
                    LyricsRowMeasurement(identity: currentIdentity, size: geometry.size)
                } action: { receiveMeasurement($0) }
                .frame(height: coordinator.height(for: identity, at: context.date), alignment: .topLeading)
        }
        // The parent and both native Text consumers receive this preference in
        // either order. Queue one latest-generation apply after their handlers;
        // it reads phase data then, rather than capturing an earlier snapshot.
        .onPreferenceChange(Text.LayoutKey.self) { _ in receivePhases() }
        .task(id: coordinator.motion?.end) {
            guard let end = coordinator.motion?.end else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            coordinator.finish(endingAt: end)
            resizeContext.clock?.clearRowDeadline(endingAt: end, owner: ObjectIdentifier(measurements))
        }
        .onChange(of: resizeContext.isVisible) { _, visible in
            measurements.invalidate()
            if let latest = measurements.latest,
               !visible || coordinator.previous != latest || coordinator.height(for: latest.identity, at: Date()) == nil {
                // The first geometry delivery can precede the real visibility
                // result. Cancelling its queued apply must retain that measured
                // static baseline for the first visible wrap.
                coordinator.observe(latest, at: Date(), delay: delay, wrapThreshold: wrapThreshold, isVisible: false)
                resizeContext.clock?.recordRowDeadline(nil, owner: ObjectIdentifier(measurements))
            }
        }
        .onDisappear {
            resizeContext.clock?.recordRowDeadline(nil, owner: ObjectIdentifier(measurements))
            coordinator = LyricsRowHeightCoordinator()
            measurements.invalidate(clearMeasurements: true)
        }
    }
#endif

    private func receiveMeasurement(_ measurement: LyricsRowMeasurement) {
        guard measurement.identity == identity else { return }
        let previous = measurements.latest
        measurements.latest = measurement
        let changed = previous?.identity != measurement.identity || previous?.size.height != measurement.size.height
        if changed {
            // Original and translation may deliver two heights in this batch.
            // Keep its original width/height, and only replace the final target.
            if !measurements.pendingGeometry || measurements.previousForPlan?.identity != measurement.identity {
                measurements.previousForPlan = previous
            }
            measurements.pendingGeometry = true
        }
        // Width-only changes still update the plain cache, but do not write
        // another State or schedule work unless a height target is pending.
        if changed || measurements.pendingGeometry { scheduleHeight() }
    }

    private func receivePhases() {
        let phaseRevision = resizeContext.clock?.revision ?? 0
        guard measurements.pendingGeometry || (coordinator.motion != nil && phaseRevision != measurements.appliedPhaseRevision) else { return }
        scheduleHeight()
    }

    private func scheduleHeight() {
        measurements.generation &+= 1
        let generation = measurements.generation
        let expectedIdentity = identity
        let cache = measurements
        let state = $coordinator
        let context = resizeContext
        let delay = delay, threshold = wrapThreshold
        DispatchQueue.main.async { [weak cache] in
            guard let cache else { return }
            Self.applyHeight(cache: cache, state: state, context: context, generation: generation,
                identity: expectedIdentity, delay: delay, threshold: threshold)
        }
    }

    private static func applyHeight(cache: LyricsRowMeasurementCache, state: Binding<LyricsRowHeightCoordinator>,
                                    context: LyricsResizeContext, generation: UInt64,
                                    identity: LyricsRowContentIdentity, delay: TimeInterval, threshold: CGFloat) {
        guard cache.generation == generation,
              let latest = cache.latest, latest.identity == identity else { return }
        let now = Date()
        let phases = context.clock?.snapshot(at: now)
        let prior = cache.previousForPlan ?? state.wrappedValue.previous
        let needsPhase = context.isVisible && context.clock != nil
            && prior?.identity == latest.identity
            && abs((prior?.size.height ?? latest.size.height) - latest.size.height) >= threshold
            && (phases?.phases.isEmpty ?? true)
        if needsPhase {
            // Geometry and Text.Layout are independent native deliveries. Give
            // the two owners one frame, bounded across newer targets, to merge.
            // A newer preference callback supersedes this queued generation.
            let deadline = cache.phaseWaitDeadline ?? now.addingTimeInterval(1.0 / 60)
            cache.phaseWaitDeadline = deadline
            if now < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSince(now))) { [weak cache] in
                    guard let cache else { return }
                    Self.applyHeight(cache: cache, state: state, context: context, generation: generation,
                        identity: identity, delay: delay, threshold: threshold)
                }
                return
            }
        }
        cache.pendingGeometry = false; cache.phaseWaitDeadline = nil
        var next = state.wrappedValue
        let timing = context.timing(at: now, fallbackDelay: delay)
        next.observe(latest, at: now, delay: delay, wrapThreshold: threshold,
            timingStart: timing.start, isVisible: context.isVisible,
            previousGeometry: cache.previousForPlan, phaseSnapshot: phases)
        cache.appliedPhaseRevision = context.clock?.revision ?? 0
        state.wrappedValue = next
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
        NativeLyricsHeightCheckEvents.rowPhaseRead?(phases?.ownerCount ?? 0, cache.appliedPhaseRevision)
#endif
        context.clock?.recordRowDeadline(next.motion?.end, owner: ObjectIdentifier(cache))
    }
}

private final class LyricsRowMeasurementCache {
    var latest: LyricsRowMeasurement?
    var previousForPlan: LyricsRowMeasurement?
    var pendingGeometry = false
    var appliedPhaseRevision: UInt64 = 0
    var generation: UInt64 = 0
    var phaseWaitDeadline: Date?
    func invalidate(clearMeasurements: Bool = false) {
        generation &+= 1; pendingGeometry = false; phaseWaitDeadline = nil
        if clearMeasurements { latest = nil; previousForPlan = nil; appliedPhaseRevision = 0 }
    }
}

/// One row of overscan and a coalesced false edge avoid treating temporary
/// anchor compensation as a request to cancel visible glyph/height plans.
@MainActor struct LyricsResizeVisibility: ViewModifier {
    let viewport: String
    let viewportSize: CGSize
    let presentationActive: Bool
    private struct Request: Equatable { let measured: Bool; let presented: Bool }
    @Environment(\.lyricsRowMotionDelay) private var delay
    @State private var measuredVisible = false
    @State private var isVisible = false
    @State private var clock = LyricsResizeClock()

    func body(content: Content) -> some View {
        let name = viewport, size = viewportSize
        let context = LyricsResizeContext(isVisible: presentationActive && isVisible, delay: delay, clock: clock)
        let request = Request(measured: measuredVisible, presented: presentationActive)
        return content.environment(\.lyricsResizeContext, context)
            .onGeometryChange(for: Bool.self) { [name, size] geometry in
                let frame = geometry.frame(in: .named(name))
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      frame.minY.isFinite, frame.maxY.isFinite, frame.height.isFinite else { return true }
                let overscan = max(24, frame.height)
                return frame.maxY > -overscan && frame.minY < size.height + overscan
                    && frame.maxX > 0 && frame.minX < size.width
            } action: { visible in
                measuredVisible = visible
                if visible && presentationActive { isVisible = true }
            }
            .task(id: request) {
                guard !request.measured, request.presented, isVisible else { return }
                do {
                    try await Task.sleep(for: .seconds(1.0 / 60))
                    while !Task.isCancelled, let deadline = clock.activeDeadline, deadline > Date() {
                        try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                    }
                } catch { return }
                guard !Task.isCancelled else { return }
                isVisible = false; clock.reset()
            }
            .onChange(of: presentationActive) { _, active in
                if !active { isVisible = false; clock.reset() }
                else if measuredVisible { isVisible = true }
            }
            .onAppear { if presentationActive && measuredVisible { isVisible = true } }
            .onDisappear { isVisible = false; clock.reset() }
    }
}
