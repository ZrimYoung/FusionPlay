import AppKit
import SwiftUI

/// A source-only lyric presentation. It never downloads or persists lyrics.
struct LyricsView: View {
    let document: LyricsDocument
    let positionMs: UInt64?
    let loading: Bool
    let connected: Bool
    let compact: Bool
    let canSeek: Bool
    let seek: (UInt64) -> Void

    @AppStorage("appLanguage") private var language = "zh-Hans"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var browsing = false
    @State private var browsingRevision = 0
    @State private var followPosition = LyricsFollowPosition()

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
                                    .visualEffect { [height = geometry.size.height, maximumBlur, maximumTopBlur] content, row in
                                        content.blur(radius: Self.edgeBlurRadius(
                                            frame: row.frame(in: .named("fusionplay.lyrics.viewport")),
                                            viewportHeight: height, topMaximum: maximumTopBlur,
                                            bottomMaximum: maximumBlur))
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
                        LyricsScrollActivity { userBeganBrowsing() }
                    }
                    .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in userBeganBrowsing() })
                    .mask(LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.09),
                        .init(color: .black, location: 0.91),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .bottomTrailing) {
                        if browsing && document.isTimed {
                            Button {
                                browsing = false
                                browsingRevision &+= 1
                                follow(proxy, animated: true)
                            } label: {
                                Label(L("回到当前歌词"), systemImage: "arrow.uturn.backward")
                                    .font(.system(size: compact ? 10 : 11, weight: .medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .padding(.bottom, 2).padding(.trailing, horizontalBleed)
                            .transition(.opacity)
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async { follow(proxy, animated: false) }
                    }
                    .onChange(of: activeID) { _, _ in
                        // VoiceOver owns its reading position; do not scroll its
                        // focused line away when playback advances.
                        if !browsing && !voiceOver { follow(proxy, animated: true) }
                    }
                    .onChange(of: geometry.size) { _, _ in
                        if document.isTimed && !browsing && !voiceOver { follow(proxy, animated: false) }
                    }
                    .onChange(of: document) { _, _ in
                        DispatchQueue.main.async { follow(proxy, animated: false) }
                    }
                    .task(id: browsingRevision) {
                        guard browsing else { return }
                        do { try await Task.sleep(nanoseconds: 6_000_000_000) }
                        catch { return }
                        guard !Task.isCancelled else { return }
                        browsing = false
                        if !voiceOver { follow(proxy, animated: true) }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(L("歌词"))
                    .padding(.horizontal, -horizontalBleed)
                }
            }
        }
        .onAppear { followPosition.observe(positionMs, connected: connected) }
        .onChange(of: positionMs) { _, position in
            followPosition.observe(position, connected: connected)
        }
        .onChange(of: connected) { _, connected in
            followPosition.observe(positionMs, connected: connected)
        }
        // Keep the reset outside the empty/nonempty branch: switching tracks
        // briefly clears the document while the next LRC is parsed.
        .onChange(of: document) { _, _ in
            browsing = false
            browsingRevision &+= 1
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: browsing)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small).tint(.white.opacity(0.7))
                Text(L("正在载入歌词…"))
            } else {
                Image(systemName: connected ? "quote.bubble" : "music.note")
                    .font(.system(size: compact ? 23 : 28, weight: .light))
                    .padding(.bottom, 3)
                Text(L(connected ? "暂无歌词" : "等待你的音乐"))
                    .fontWeight(.medium)
                if connected {
                    Text(L("歌词由手机提供"))
                        .font(.system(size: compact ? 11 : 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .font(.system(size: compact ? 13 : 15))
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
                browsing = false
                browsingRevision &+= 1
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
        let size = compact ? min(28, max(20, width * 0.075)) : min(34, max(25, width * 0.075))
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
                    .font(.system(size: size, weight: .semibold))
                    .tracking(5)
                    .accessibilityLabel(L("歌词间隔"))
            } else {
                Text(line.text)
                    .font(.system(size: size, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(compact ? 1 : 3)
            }
            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: compact ? max(12, size * 0.56) : size * 0.6, weight: .semibold))
                    .opacity(0.78)
                    .fixedSize(horizontal: false, vertical: true)
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
                                                  topMaximum: CGFloat, bottomMaximum: CGFloat) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        let topBand = max(12, viewportHeight * 0.30)
        let bottomBand = max(12, viewportHeight * 0.45)
        let topAmount = 1 - min(1, max(0, frame.midY / topBand))
        let bottomDistance = viewportHeight - frame.midY
        let bottomAmount = 1 - min(1, max(0, bottomDistance / bottomBand))
        let topBlur = topMaximum * topAmount * topAmount * (3 - 2 * topAmount)
        let bottomBlur = bottomMaximum * bottomAmount * bottomAmount * (3 - 2 * bottomAmount)
        return max(topBlur, bottomBlur)
    }

    private func userBeganBrowsing() {
        guard document.isTimed else { return }
        browsing = true
        browsingRevision &+= 1
    }
    private func follow(_ proxy: ScrollViewProxy, animated: Bool) {
        // Unknown progress is not an instruction to jump to the first line.
        guard document.isTimed, followPosition.current(positionMs, connected: connected) != nil else { return }
        guard let id = activeID ?? document.lines.first?.id else { return }
        let anchor = UnitPoint(x: 0.5, y: 0.32)
        if animated && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.48)) { proxy.scrollTo(id, anchor: anchor) }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: anchor) }
        }
    }
}

private struct LyricsRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Observe only wheel events inside this lyric scroll region. Returning the
/// original event preserves native scrolling and does not capture input.
private struct LyricsScrollActivity: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> ActivityView {
        let view = ActivityView()
        view.onScroll = onScroll
        return view
    }
    func updateNSView(_ view: ActivityView, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: ActivityView, coordinator: ()) { view.disconnect() }

    final class ActivityView: NSView {
        var onScroll: (() -> Void)?
        private var monitor: Any?
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disconnect()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)),
                      event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return event }
                self.onScroll?()
                return event
            }
        }
        func disconnect() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
