import SwiftUI

private struct LyricMotionDelayKey: EnvironmentKey {
    static let defaultValue: TimeInterval = 0
}

private struct LyricLineMoveDurationKey: EnvironmentKey {
    static let defaultValue = LyricReflowTiming.defaultMoveDuration
}

extension EnvironmentValues {
    var lyricLineMoveDuration: TimeInterval {
        get { self[LyricLineMoveDurationKey.self] }
        set { self[LyricLineMoveDurationKey.self] = newValue }
    }

    var lyricMotionDelay: TimeInterval {
        get { self[LyricMotionDelayKey.self] }
        set { self[LyricMotionDelayKey.self] = newValue }
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
    @Environment(\.lyricMotionDelay) private var motionDelay
    @Environment(\.lyricLineMoveDuration) private var moveDuration
    let text: Text
    let overflow: CGFloat
    @State private var target: GlyphLayout?
    @State private var motion = GlyphMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: motion.endsAt == nil)) { context in
            text.textRenderer(ReflowRenderer(target: target, motion: motion, now: context.date, overflow: overflow))
        }
        .onPreferenceChange(Text.LayoutKey.self) { layouts in
            guard let layout = layouts.first?.layout else { return }
            accept(GlyphLayout(layout))
        }
        .task(id: motion.endsAt) {
            guard let end = motion.endsAt else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
            if motion.endsAt == end { motion = GlyphMotion() }
        }
    }

    private func accept(_ measured: GlyphLayout) {
        guard target != measured else { return }
        if let previous = target {
            motion = motion.retarget(from: previous, to: measured, now: Date(), delay: motionDelay,
                                     moveDuration: moveDuration)
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
private struct GlyphDissolve {
    private static let maximumBlur: CGFloat = 4
    private static let blurLead = 0.24
    let from: GlyphAppearance
    let startedAt: Date
    let duration: TimeInterval
    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    func appearance(at destination: CGPoint, now: Date) -> GlyphAppearance? {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let progress = elapsed / duration
        if progress < LyricReflowTiming.hideEnd {
            let phase = progress / LyricReflowTiming.hideEnd
            let fade = Self.ease((phase - Self.blurLead) / (1 - Self.blurLead))
            let blur = from.blur + (Self.maximumBlur - from.blur) * CGFloat(Self.ease(phase))
            return GlyphAppearance(origin: from.origin, opacity: from.opacity * (1 - fade), blur: blur)
        }
        if progress < LyricReflowTiming.showStart {
            return GlyphAppearance(origin: destination, opacity: 0, blur: Self.maximumBlur)
        }
        guard progress < 1 else { return nil }
        let phase = Self.ease((progress - LyricReflowTiming.showStart) / (1 - LyricReflowTiming.showStart))
        return GlyphAppearance(origin: destination, opacity: phase, blur: Self.maximumBlur * CGFloat(1 - phase))
    }

    private static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}

private struct GlyphSlide {
    let origin: CGPoint
    let startedAt: Date
    let duration: TimeInterval
    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    func position(at destination: CGPoint, now: Date) -> CGPoint {
        let remaining = 1 - min(1, max(0, now.timeIntervalSince(startedAt) / duration))
        let ease = CGFloat(remaining * remaining * remaining)
        return CGPoint(x: destination.x + (origin.x - destination.x) * ease,
                       y: destination.y + (origin.y - destination.y) * ease)
    }
}

@available(iOS 18.0, *)
private struct GlyphMotion {
    var dissolves: [GlyphLayout.Key: GlyphDissolve] = [:]
    var slides: [GlyphLayout.Key: GlyphSlide] = [:]

    var endsAt: Date? {
        let slideEnd = slides.values.lazy.map(\.endsAt).max()
        let dissolveEnd = dissolves.values.lazy.map(\.endsAt).max()
        if let slideEnd, let dissolveEnd { return max(slideEnd, dissolveEnd) }
        return slideEnd ?? dissolveEnd
    }

    func appearance(_ key: GlyphLayout.Key, at destination: CGPoint, now: Date) -> GlyphAppearance? {
        if let fading = dissolves[key]?.appearance(at: destination, now: now) { return fading }
        guard let slide = slides[key], slide.endsAt > now else { return nil }
        return GlyphAppearance(origin: slide.position(at: destination, now: now))
    }

    func retarget(from previous: GlyphLayout, to target: GlyphLayout, now: Date,
                  delay: TimeInterval, moveDuration: TimeInterval) -> Self {
        let start = now.addingTimeInterval(LyricReflowTiming.staggerDelay(span: delay, position: 1))
        let dissolveDuration = LyricReflowTiming.reflowDuration(moveDuration: moveDuration)
        let slideDuration = LyricReflowTiming.slideDuration(moveDuration: moveDuration)
        var nextDissolves: [GlyphLayout.Key: GlyphDissolve] = [:]
        var nextSlides: [GlyphLayout.Key: GlyphSlide] = [:]

        for (key, destination) in target.positions {
            guard let prior = previous.positions[key] else { continue }
            let dissolving = dissolves[key].flatMap { $0.endsAt > now ? $0 : nil }
            let sliding = slides[key].flatMap { $0.endsAt > now ? $0 : nil }
            let visible = sliding?.position(at: prior.origin, now: now) ?? prior.origin
            if prior.line != destination.line {
                let from = dissolving?.appearance(at: prior.origin, now: now) ?? GlyphAppearance(origin: visible)
                nextDissolves[key] = GlyphDissolve(from: from, startedAt: start, duration: dissolveDuration)
            } else if let dissolving {
                // Another glyph can wrap without restarting this glyph's fade.
                nextDissolves[key] = dissolving
            } else if Self.hasDisplacement(from: prior.origin, to: destination.origin) {
                if Self.hasDisplacement(from: visible, to: destination.origin) {
                    nextSlides[key] = GlyphSlide(origin: visible, startedAt: start, duration: slideDuration)
                }
            } else if let sliding {
                nextSlides[key] = sliding
            }
        }

        return GlyphMotion(dissolves: nextDissolves, slides: nextSlides)
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
                    let animated = motion.appearance(key, at: destination.origin, now: now)
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
                    let blurStep = Int((appearance.blur * 4).rounded())
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
            filtered.addFilter(.blur(radius: CGFloat(step) / 4))
            filtered.drawLayer { layer in
                for glyph in glyphs { glyph.draw(in: layer) }
            }
        }
    }
}
