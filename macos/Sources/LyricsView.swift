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
                        LazyVStack(alignment: .leading, spacing: compact ? 12 : 20) {
                            ForEach(document.lines.indices, id: \.self) { index in
                                let line = document.lines[index]
                                lyricRow(line, index: index, width: geometry.size.width)
                                    .background {
                                        LyricsViewportRowProbe(id: line.id, anchor: viewportAnchor)
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
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
                        if !browsing && !dragging && !voiceOver && !liveResizing && !viewportSettling {
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
                        guard !Task.isCancelled, presentationActive, !liveResizing else { return }
                        presentationFollowRequest = presentationRevision
                    }
                    .onChange(of: presentationFollowRequest) { _, revision in
                        guard revision == presentationRevision, presentationActive, needsPresentationFollow,
                              !viewportSettling, !liveResizing else { return }
                        needsPresentationFollow = false
                        viewportAnchor.cancel()
                        follow(proxy, animated: false, reason: "presentation")
                    }
                    .onChange(of: geometry.size) { _, _ in viewportChanged() }
                    .task(id: viewportRevision) {
                        guard viewportRevision > 0, presentationActive, !liveResizing else { return }
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
                        guard !Task.isCancelled, presentationActive, !liveResizing else { return }
                        viewportSettling = false
                        // Trigger a fresh view callback after the quiet period;
                        // an async task's captured playback position can be old.
                        viewportFollowRequest = viewportRevision
                    }
                    .onChange(of: viewportFollowRequest) { _, revision in
                        guard revision == viewportRevision, presentationActive, !viewportSettling, !liveResizing else { return }
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
                            if !liveResizing && !viewportSettling { follow(proxy, animated: false, reason: "document") }
                        }
                    }
                    .onChange(of: followRequestRevision) { _, revision in
                        guard let revision, revision == browsingRevision, !browsing, !voiceOver else { return }
                        // Resolve the target from the latest playback value,
                        // not the view captured before the inactivity delay.
                        guard !liveResizing && !viewportSettling else { return }
                        follow(proxy, animated: true, reason: "resume")
                    }
                    .task(id: browsingRevision) {
                        guard browsing else { return }
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                        catch { return }
                        // A held drag may be stationary for longer than the
                        // delay. Its end starts a fresh inactivity countdown.
                        guard !Task.isCancelled, !dragging, !liveResizing, !viewportSettling else { return }
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
        let baseSize = compact ? min(28, max(20, width * 0.075)) : min(34, max(25, width * 0.075))
        let scale = LyricsTypography.scale(percent: lyricsFontScalePercent)
        let size = baseSize * scale
        let translationSize = (compact ? max(12, baseSize * 0.56) : baseSize * 0.6) * scale
        let opacity: Double = {
            if !document.isTimed { return 0.88 }
            if active { return 1 }
            if contrast == .increased { return 0.74 }
            guard let activeIndex else { return index == 0 ? 0.72 : 0.4 }
            return abs(index - activeIndex) <= 1 ? 0.56 : 0.3
        }()
        return VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            if line.text.isEmpty {
                Text("•••")
                    .font(typography.font(size: size, weight: .semibold))
                    .tracking(5)
                    .accessibilityLabel(L("歌词间隔"))
            } else {
                LyricsReflowText(text: line.text, font: typography.nsFont(size: size, weight: .bold),
                                 lineSpacing: compact ? 1 : 3, reduceMotion: reduceMotion,
                                 width: max(1, width - 6))
            }
            if let translation = line.translation, !translation.isEmpty {
                LyricsReflowText(text: translation,
                                 font: typography.nsFont(size: translationSize, weight: .semibold),
                                 lineSpacing: 0, reduceMotion: reduceMotion, width: max(1, width - 6))
                    .opacity(0.78)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, compact ? 3 : 5)
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
        viewportAnchor.configure(activeID: activeID, browsing: browsing, enabled: !voiceOver)
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
        guard presentationActive, !browsing, !dragging, !voiceOver, !liveResizing, !viewportSettling else { return }
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
    let onScroll: () -> Void
    let onLiveResize: (Bool) -> Void
    func makeNSView(context: Context) -> ActivityView {
        let view = ActivityView()
        view.anchor = anchor
        anchor.configure(activeID: activeID, browsing: browsing, enabled: anchoringEnabled)
        view.onScroll = onScroll
        view.onLiveResize = onLiveResize
        return view
    }
    func updateNSView(_ view: ActivityView, context: Context) {
        view.anchor = anchor
        anchor.configure(activeID: activeID, browsing: browsing, enabled: anchoringEnabled)
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
