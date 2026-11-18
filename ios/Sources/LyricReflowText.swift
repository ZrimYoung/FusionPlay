import SwiftUI

enum LyricReflowTiming {
    static let duration = 0.48
    static let hideEnd = 0.31
    static let rowStart = 0.34
    static let rowEnd = 0.64
    static let showStart = 0.68
    static let slideDuration = 0.19

    static let staggerRange = 0...240
    static let defaultStaggerMilliseconds = 140
    static let staggerStep = 10
    static let maximumStaggerSpan = TimeInterval(staggerRange.upperBound) / 1_000

    static func clampedStaggerMilliseconds(_ value: Int) -> Int {
        min(staggerRange.upperBound, max(staggerRange.lowerBound, value))
    }

    static func staggerSpan(milliseconds: Int) -> TimeInterval {
        TimeInterval(clampedStaggerMilliseconds(milliseconds)) / 1_000
    }

    static func staggerDelay(span: TimeInterval, position: Double) -> TimeInterval {
        min(1, max(0, position)) * min(maximumStaggerSpan, max(0, span))
    }
}

private struct LyricMotionDelayKey: EnvironmentKey {
    static let defaultValue: TimeInterval = 0
}

extension EnvironmentValues {
    var lyricMotionDelay: TimeInterval {
        get { self[LyricMotionDelayKey.self] }
        set { self[LyricMotionDelayKey.self] = newValue }
    }
}

struct LyricReflowText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    let value: String
    let size: CGFloat
    let weight: Font.Weight
    let lineSpacing: CGFloat

    init(_ value: String, size: CGFloat, weight: Font.Weight, lineSpacing: CGFloat = 0) {
        self.value = value
        self.size = size
        self.weight = weight
        self.lineSpacing = lineSpacing
    }

    var body: some View {
        let text = Text(verbatim: value).font(.system(size: size, weight: weight))
        Group {
            if #available(iOS 18.0, *), !reduceMotion, !voiceOver, value.utf8.count <= 1_024 {
                AnimatedLyricText(text: text, overflow: min(120, max(8, size * 2)))
                    .id(value)
            } else {
                text
            }
        }
        .lineSpacing(lineSpacing)
    }
}

@available(iOS 18.0, *)
private struct AnimatedLyricText: View {
    @Environment(\.lyricMotionDelay) private var motionDelay
    let text: Text
    let overflow: CGFloat
    @State private var target: GlyphLayout?
    @State private var motion = GlyphMotion()

    var body: some View {
        TimelineView(.animation(paused: motion.endsAt == nil)) { context in
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
            motion = motion.retarget(from: previous, to: measured, now: Date(), delay: motionDelay)
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
    var endsAt: Date { startedAt.addingTimeInterval(LyricReflowTiming.duration) }

    func appearance(at destination: CGPoint, now: Date) -> GlyphAppearance? {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let progress = elapsed / LyricReflowTiming.duration
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
    var endsAt: Date { startedAt.addingTimeInterval(LyricReflowTiming.slideDuration) }

    func position(at destination: CGPoint, now: Date) -> CGPoint {
        let remaining = 1 - min(1, max(0, now.timeIntervalSince(startedAt) / LyricReflowTiming.slideDuration))
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

    func retarget(from previous: GlyphLayout, to target: GlyphLayout, now: Date, delay: TimeInterval) -> Self {
        let start = now.addingTimeInterval(LyricReflowTiming.staggerDelay(span: delay, position: 1))
        var nextDissolves: [GlyphLayout.Key: GlyphDissolve] = [:]
        var nextSlides: [GlyphLayout.Key: GlyphSlide] = [:]

        for (key, destination) in target.positions {
            guard let prior = previous.positions[key] else { continue }
            let dissolving = dissolves[key].flatMap { $0.endsAt > now ? $0 : nil }
            let sliding = slides[key].flatMap { $0.endsAt > now ? $0 : nil }
            let visible = sliding?.position(at: prior.origin, now: now) ?? prior.origin
            if prior.line != destination.line {
                let from = dissolving?.appearance(at: prior.origin, now: now) ?? GlyphAppearance(origin: visible)
                nextDissolves[key] = GlyphDissolve(from: from, startedAt: start)
            } else if let dissolving {
                // Another glyph can wrap without restarting this glyph's fade.
                nextDissolves[key] = dissolving
            } else if Self.hasDisplacement(from: prior.origin, to: destination.origin) {
                if Self.hasDisplacement(from: visible, to: destination.origin) {
                    nextSlides[key] = GlyphSlide(origin: visible, startedAt: start)
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
