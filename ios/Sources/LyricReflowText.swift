import SwiftUI

private struct LyricResizeContextKey: EnvironmentKey {
    static let defaultValue = LyricResizeContext()
}

private struct LyricLineMoveDurationKey: EnvironmentKey {
    static let defaultValue = LyricReflowTiming.defaultMoveDuration
}

extension EnvironmentValues {
    var lyricLineMoveDuration: TimeInterval {
        get { self[LyricLineMoveDurationKey.self] }
        set { self[LyricLineMoveDurationKey.self] = newValue }
    }

    var lyricResizeContext: LyricResizeContext {
        get { self[LyricResizeContextKey.self] }
        set { self[LyricResizeContextKey.self] = newValue }
    }
}

struct LyricReflowText: View {
    @Environment(\.receiverTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    let value: String
    let size: CGFloat
    let scale: CGFloat
    let weight: Font.Weight
    let lineSpacing: CGFloat

    init(_ value: String, size: CGFloat, scale: CGFloat, weight: Font.Weight, lineSpacing: CGFloat = 0) {
        self.value = value
        self.size = size
        self.scale = scale
        self.weight = weight
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        if #available(iOS 18.0, *), !reduceMotion, !voiceOver, value.utf8.count <= 1_024 {
            let text = Text(verbatim: value).font(typography.font(size: size, weight: weight))
            ScaledLyricTextLayout(scale: scale) {
                AnimatedLyricText(text: text, overflow: min(120 / scale, max(8 / scale, size * 2)))
                    .id(value)
                    .id(typography.face)
                    .lineSpacing(lineSpacing)
                    .scaleEffect(scale, anchor: .topLeading)
            }
            .animation(nil, value: scale)
        } else {
            Text(verbatim: value)
                .font(typography.font(size: size * scale, weight: weight))
                .lineSpacing(lineSpacing)
        }
    }
}

/// Keep the renderer's glyph positions in one font coordinate system. The
/// layout measures the available width there, then scales all the ink together.
private struct ScaledLyricTextLayout: Layout {
    let scale: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let size = text.sizeThatFits(unscaled(proposal))
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: unscaled(proposal))
    }

    private func unscaled(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width.map { $0 / scale }, height: proposal.height.map { $0 / scale })
    }
}

@available(iOS 18.0, *)
private struct AnimatedLyricText: View {
    @Environment(\.lyricResizeContext) private var resizeContext
    let text: Text
    let overflow: CGFloat
    @State private var target: GlyphLayout?
    @State private var motion = GlyphMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: motion.endsAt == nil)) { context in
            text.textRenderer(ReflowRenderer(target: resizeContext.isVisible ? target : nil,
                                             motion: motion, now: context.date, overflow: overflow))
        }
        .onPreferenceChange(Text.LayoutKey.self) { layouts in
            guard let layout = layouts.first?.layout else { return }
            accept(GlyphLayout(layout))
        }
        .onChange(of: resizeContext.isVisible) { _, visible in
            if !visible { motion = GlyphMotion() }
        }
        .task(id: motion.endsAt) {
            guard let end = motion.endsAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
            if motion.endsAt == end { motion = GlyphMotion() }
        }
    }

    private func accept(_ measured: GlyphLayout) {
        guard target != measured else { return }
        if let previous = target, resizeContext.isVisible,
           previous.lineStarts != measured.lineStarts || motion.endsAt != nil {
            let now = Date()
            motion = motion.retarget(from: previous, to: measured, now: now,
                                     timing: resizeContext.timing(at: now))
        } else {
            motion = GlyphMotion()
        }
        target = measured
    }
}

@available(iOS 18.0, *)
private struct GlyphLayout: Equatable {
    typealias Key = [Text.Layout.CharacterIndex]
    struct Position: Equatable {
        let origin: CGPoint
        let line: Int
    }

    private struct LinePair: Hashable {
        let old: Int
        let new: Int
    }

    let lineStarts: [Text.Layout.CharacterIndex?]
    let lineWidths: [CGFloat]
    let positions: [Key: Position]

    init(_ layout: Text.Layout) {
        let anchor = layout.first?.origin ?? .zero
        var positions: [Key: Position] = [:]
        var ambiguous: Set<Key> = []
        for (lineIndex, line) in layout.enumerated() {
            for run in line {
                for slice in run {
                    let key = Self.key(for: slice)
                    guard !key.isEmpty else { continue }
                    let origin = slice.typographicBounds.origin
                    let relative = Position(origin: CGPoint(x: origin.x - anchor.x, y: origin.y - anchor.y),
                                            line: lineIndex)
                    if positions.updateValue(relative, forKey: key) != nil {
                        ambiguous.insert(key)
                    }
                }
            }
        }
        lineStarts = Self.starts(in: layout)
        lineWidths = layout.map { $0.typographicBounds.width }
        for key in ambiguous { positions.removeValue(forKey: key) }
        self.positions = positions
    }

    /// Match continuing visual lines by the native clusters they share. A row
    /// pushed down wholesale still belongs to the same fragment of the lyric.
    func continuingLines(from previous: Self) -> [Int: Int] {
        var overlap: [LinePair: Int] = [:]
        for (key, position) in positions {
            guard let prior = previous.positions[key] else { continue }
            overlap[LinePair(old: prior.line, new: position.line), default: 0] += key.count
        }

        func preferred(_ candidate: LinePair, over current: LinePair?) -> Bool {
            guard let current else { return true }
            let candidateKeepsStart = previous.lineStarts[candidate.old] == lineStarts[candidate.new]
            let currentKeepsStart = previous.lineStarts[current.old] == lineStarts[current.new]
            if candidateKeepsStart != currentKeepsStart { return candidateKeepsStart }
            let candidateOverlap = overlap[candidate, default: 0]
            let currentOverlap = overlap[current, default: 0]
            if candidateOverlap != currentOverlap { return candidateOverlap > currentOverlap }
            if candidate.old != current.old { return candidate.old < current.old }
            return candidate.new < current.new
        }

        var bestFromOld: [Int: LinePair] = [:]
        var bestFromNew: [Int: LinePair] = [:]
        for pair in overlap.keys {
            if preferred(pair, over: bestFromOld[pair.old]) { bestFromOld[pair.old] = pair }
            if preferred(pair, over: bestFromNew[pair.new]) { bestFromNew[pair.new] = pair }
        }
        return bestFromOld.compactMapValues { bestFromNew[$0.new] == $0 ? $0.new : nil }
    }

    func matches(_ layout: Text.Layout) -> Bool {
        lineStarts == Self.starts(in: layout)
            && zip(lineWidths, layout).allSatisfy { abs($0 - $1.typographicBounds.width) < 0.75 }
    }

    private static func starts(in layout: Text.Layout) -> [Text.Layout.CharacterIndex?] {
        layout.map { line in line.lazy.compactMap { $0.characterIndices.min() }.min() }
    }

    static func key(for slice: Text.Layout.RunSlice) -> Key {
        slice.characterIndices.sorted()
    }
}

private struct GlyphAppearance {
    let origin: CGPoint
    var opacity: Double = 1
    var blur: CGFloat = 0
}

@available(iOS 18.0, *)
private struct GlyphTransition {
    static let maximumBlur: CGFloat = 3
    static let blurSteps = 3
    private static let minimumRetargetTime: TimeInterval = 0.065

    let from: GlyphAppearance
    let destination: CGPoint
    let start: Date
    let end: Date
    var wrap: LyricResizeTiming?
    var hasWrapped = false

    func appearance(at now: Date) -> GlyphAppearance {
        if wrap != nil {
            let progress = now.timeIntervalSince(start) / LyricResizeTiming.duration
            if progress < LyricResizeTiming.fadeOutEnd {
                let phase = progress / LyricResizeTiming.fadeOutEnd
                let fade = LyricResizeTiming.ease(phase)
                // Soften the ink while it is still visible.
                let softening = CGFloat(LyricResizeTiming.ease(phase / 0.72))
                return GlyphAppearance(origin: from.origin, opacity: from.opacity * (1 - fade),
                                       blur: from.blur + (Self.maximumBlur - from.blur) * softening)
            }
            let phase = (progress - LyricResizeTiming.revealStart) / (1 - LyricResizeTiming.revealStart)
            let reveal = LyricResizeTiming.ease(phase)
            let sharpening = LyricResizeTiming.ease((phase - 0.14) / 0.86)
            return GlyphAppearance(origin: destination, opacity: reveal,
                                   blur: Self.maximumBlur * CGFloat(1 - sharpening))
        }

        let progress = LyricResizeTiming.ease(now.timeIntervalSince(start) / end.timeIntervalSince(start))
        let offset = CGFloat(1 - progress)
        return GlyphAppearance(origin: CGPoint(x: destination.x + (from.origin.x - destination.x) * offset,
                                               y: destination.y + (from.origin.y - destination.y) * offset),
                               opacity: 1 + (from.opacity - 1) * (1 - progress), blur: from.blur * offset)
    }

    func retarget(to next: CGPoint, at now: Date) -> Self {
        if let wrap, now < wrap.reveal, GlyphMotion.hasDisplacement(from: from.origin, to: next) {
            // The outgoing ink still occupies its old location. The new
            // placement can change freely before the fragment becomes visible.
            return Self(from: from, destination: next, start: start, end: end, wrap: wrap, hasWrapped: true)
        }
        let sample = appearance(at: now)
        let nextStart = max(now, start)
        return Self(from: sample, destination: next, start: nextStart,
                    end: max(end, nextStart.addingTimeInterval(Self.minimumRetargetTime)), hasWrapped: hasWrapped)
    }
}

@available(iOS 18.0, *)
private struct GlyphMotion {
    private let transitions: [GlyphLayout.Key: GlyphTransition]
    let endsAt: Date?

    init(_ transitions: [GlyphLayout.Key: GlyphTransition] = [:]) {
        self.transitions = transitions
        endsAt = transitions.values.lazy.map(\.end).max()
    }

    func appearance(_ key: GlyphLayout.Key, now: Date) -> GlyphAppearance? {
        guard let transition = transitions[key], now < transition.end else { return nil }
        return transition.appearance(at: now)
    }

    func retarget(from previous: GlyphLayout, to target: GlyphLayout, now: Date,
                  timing: LyricResizeTiming) -> Self {
        let continuingLines = target.continuingLines(from: previous)
        var next: [GlyphLayout.Key: GlyphTransition] = [:]

        for (key, destination) in target.positions {
            guard let prior = previous.positions[key] else { continue }
            let running = transitions[key].flatMap { $0.end > now ? $0 : nil }
            if let running, running.destination == destination.origin {
                next[key] = running
                continue
            }
            let crossesLine = continuingLines[prior.line] != destination.line
            let visible = running?.appearance(at: now) ?? GlyphAppearance(origin: prior.origin)
            guard running != nil || Self.hasDisplacement(from: visible.origin, to: destination.origin) else {
                continue
            }

            // A first wrap fades the fragment's native clusters in phase.
            // A second wrap during the same gesture continues their visible motion.
            if crossesLine, running?.hasWrapped != true {
                next[key] = GlyphTransition(from: visible, destination: destination.origin,
                                            start: timing.start, end: timing.end, wrap: timing, hasWrapped: true)
            } else if let running {
                next[key] = running.retarget(to: destination.origin, at: now)
            } else {
                next[key] = GlyphTransition(from: visible, destination: destination.origin, start: timing.start,
                                            end: timing.start.addingTimeInterval(LyricResizeTiming.slideDuration))
            }
        }
        return Self(next)
    }

    static func hasDisplacement(from origin: CGPoint, to destination: CGPoint) -> Bool {
        abs(origin.x - destination.x) >= 0.75 || abs(origin.y - destination.y) >= 0.75
    }
}

@available(iOS 18.0, *)
private struct ReflowRenderer: TextRenderer {
    private struct GlyphDraw {
        let slice: Text.Layout.RunSlice
        let offset: CGPoint
        let opacity: Double

        func draw(in context: GraphicsContext) {
            var ink = context
            ink.opacity *= opacity
            ink.translateBy(x: offset.x, y: offset.y)
            ink.draw(slice)
        }
    }

    let target: GlyphLayout?
    let motion: GlyphMotion
    let now: Date
    let overflow: CGFloat

    // Vertical room keeps disappearing glyphs from a removed line drawable while
    // the row shrinks. Horizontal padding would change line breaks.
    var displayPadding: EdgeInsets { EdgeInsets(top: 4, leading: 0, bottom: overflow, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        guard let target else {
            for line in layout { context.draw(line) }
            return
        }
        let matches = target.matches(layout)
        guard !matches || motion.endsAt != nil else {
            for line in layout { context.draw(line) }
            return
        }
        let anchor = layout.first?.origin ?? .zero
        let blurIncrement = GlyphTransition.maximumBlur / CGFloat(GlyphTransition.blurSteps)
        var blurLayers: [Int: [GlyphDraw]] = [:]
        for line in layout {
            for run in line {
                for slice in run {
                    let key = GlyphLayout.key(for: slice)
                    guard let destination = target.positions[key] else {
                        context.draw(slice)
                        continue
                    }
                    let nativeOrigin = slice.typographicBounds.origin
                    let origin = matches ? destination.origin :
                        CGPoint(x: nativeOrigin.x - anchor.x, y: nativeOrigin.y - anchor.y)
                    let animated = motion.appearance(key, now: now)
                    if animated == nil, !GlyphMotion.hasDisplacement(from: origin, to: destination.origin) {
                        context.draw(slice)
                        continue
                    }
                    // Until a new measurement arrives, keep moved clusters at
                    // the previous presentation in the current text coordinate space.
                    let appearance = animated ?? GlyphAppearance(origin: destination.origin)
                    guard appearance.opacity > 0 else { continue }
                    let glyph = GlyphDraw(slice: slice,
                        offset: CGPoint(x: appearance.origin.x - origin.x, y: appearance.origin.y - origin.y),
                        opacity: appearance.opacity)
                    let blurStep = Int((appearance.blur / blurIncrement).rounded())
                    if blurStep == 0 {
                        glyph.draw(in: context)
                    } else {
                        blurLayers[blurStep, default: []].append(glyph)
                    }
                }
            }
        }
        for (step, glyphs) in blurLayers.sorted(by: { $0.key < $1.key }) {
            var filtered = context
            filtered.addFilter(.blur(radius: CGFloat(step) * blurIncrement))
            filtered.drawLayer { layer in
                for glyph in glyphs { glyph.draw(in: layer) }
            }
        }
    }
}
