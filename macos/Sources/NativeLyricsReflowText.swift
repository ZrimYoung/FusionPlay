import AppKit
import SwiftUI

#if compiler(>=6.0)
/// The same native TextRenderer and CharacterIndex cluster motion used by the
/// FusionPlay iPad player. No glyph is rasterized or reshaped by this path.
@available(macOS 15.0, *)
@MainActor
struct NativeLyricsReflowText: View {
    let text: String
    let font: NSFont
    let lineSpacing: CGFloat
    let reduceMotion: Bool
    let width: CGFloat
    var motionDelay: Double = 0
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var target: NativeGlyphLayout?
    @State private var motion = NativeGlyphMotion()
    @State private var rowMotion: NativeLyricRowMotion?
    @State private var naturalHeight: CGFloat?
    @State private var intrinsicSize: CGSize?
    @State private var pendingHeightTopology = false
    @State private var input: NativeLyricInput?
    @State private var revision: UInt64 = 0
    @State private var layoutCount = 0
    @State private var direction = "none"
    @State private var clock: Date?
#if FUSIONPLAY_UI_CHECKS
    @State private var checkOwner = UUID()
#endif

    private var safeWidth: CGFloat { width.isFinite ? max(1, width) : 1 }
    private var allowed: Bool { !reduceMotion && !voiceOver && text.utf8.count <= 1_024 }
    private var identity: NativeLyricIdentity { NativeLyricIdentity(text: text, font: font) }
    private var end: Date? {
        if let a = motion.endsAt, let b = rowMotion?.end { return max(a, b) }
        return motion.endsAt ?? rowMotion?.end
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: end == nil)) { context in
            Text(verbatim: text).font(Font(font))
                .textRenderer(NativeReflowRenderer(target: target, motion: motion, now: context.date,
                                                  overflow: min(120, max(8, font.pointSize * 2))))
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: safeWidth, alignment: .topLeading)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                    intrinsicSize = size
                    let topology = pendingHeightTopology
                    pendingHeightTopology = false
                    acceptHeight(size.height, topologyChanged: topology, at: Date())
                }
                .frame(height: rowMotion?.height(at: context.date) ?? naturalHeight, alignment: .topLeading)
        }
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onPreferenceChange(Text.LayoutKey.self) { layouts in
            guard let native = layouts.first?.layout else { return }
            accept(NativeGlyphLayout(native, width: safeWidth, identity: identity))
        }
        .onChange(of: identity) { _, _ in reset(clearLayout: true) }
        .onChange(of: allowed) { _, enabled in if !enabled { reset(clearLayout: false) } }
        .onAppear { installSampler() }
        .task(id: revision) { await finishMotion() }
        .onDisappear { reset(clearLayout: false); removeSampler() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func accept(_ measured: NativeGlyphLayout) {
        input = NativeLyricInput(text: text, font: font, spacing: lineSpacing, width: safeWidth)
        guard target != measured else { return }
        layoutCount += 1
        let now = Date()
        let previous = target
        let changedWrap = previous.map { $0.lineStarts != measured.lineStarts } ?? false
        let start = now.addingTimeInterval(LyricsStaggerTiming.clampSpan(motionDelay))
        if let previous, allowed, previous.identity == measured.identity {
            if changedWrap {
                direction = measured.height > previous.height + 0.5 ? "expand" :
                    measured.height < previous.height - 0.5 ? "contract" : "reflow"
                clock = start
            } else if end == nil { direction = "position"; clock = start }
            motion = motion.retarget(from: previous, to: measured, now: now, start: start)
        } else {
            motion = NativeGlyphMotion(); rowMotion = nil; direction = "none"; clock = nil
        }
        target = measured
        // Native Text's intrinsic geometry is the sole source of row height.
        // Typographic bounds below are used only to describe wrap direction.
        if changedWrap {
            pendingHeightTopology = true
            if let intrinsicSize, abs(intrinsicSize.width - safeWidth) < 0.75 {
                pendingHeightTopology = false
                acceptHeight(intrinsicSize.height, topologyChanged: true, at: now)
            }
        }
        revision &+= 1
#if FUSIONPLAY_UI_CHECKS
        if changedWrap && allowed { LyricsReflowTextCheckEvents.transition?("begin", end == nil ? 0 : 1) }
        if previous == nil { LyricsReflowTextCheckEvents.transition?("reset", 0) }
#endif
        report(previous == nil ? "reset" : changedWrap && allowed ? "begin" : "retarget")
        if changedWrap && allowed { report(phase(at: now)) }
    }

    private func acceptHeight(_ height: CGFloat, topologyChanged: Bool, at now: Date) {
        guard height.isFinite, height >= 0 else { return }
        guard let previous = naturalHeight, allowed, target != nil else {
            naturalHeight = height; rowMotion = nil; return
        }
        guard topologyChanged || abs(previous - height) > 0.25 else { return }
        let visible = rowMotion?.height(at: now) ?? previous
        naturalHeight = height
        if let running = rowMotion, now < running.end, !topologyChanged {
            rowMotion = NativeLyricRowMotion(from: visible, target: height,
                start: max(now, running.start), end: running.end)
        } else if topologyChanged || abs(previous - height) >= max(8, font.pointSize * 0.6) {
            let start = clock ?? now.addingTimeInterval(LyricsStaggerTiming.clampSpan(motionDelay))
            rowMotion = NativeLyricRowMotion(from: visible, target: height,
                start: start.addingTimeInterval(NativeLyricTiming.duration * NativeLyricTiming.rowStart),
                end: start.addingTimeInterval(NativeLyricTiming.duration * NativeLyricTiming.rowEnd))
        } else { rowMotion = nil }
        revision &+= 1
        report("measure")
    }

    private func reset(clearLayout: Bool) {
        revision &+= 1; motion = NativeGlyphMotion(); rowMotion = nil; clock = nil; direction = "none"
        pendingHeightTopology = false
        if clearLayout && target?.identity != identity {
            target = nil; naturalHeight = intrinsicSize?.height; input = nil
        }
#if FUSIONPLAY_UI_CHECKS
        LyricsReflowTextCheckEvents.transition?("reset", 0)
#endif
        report("reset")
    }

    private func finishMotion() async {
        guard let expected = end else { return }
        let token = revision
        let expectedIdentity = identity
        // A stalled main thread can start this task after its last deadline.
        // Always stop the timeline rather than retaining an expired motion.
        if expected <= Date() {
            motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
#if FUSIONPLAY_UI_CHECKS
            LyricsReflowTextCheckEvents.transition?("end", 0)
#endif
            report("end")
            return
        }
        var boundaries = motion.dissolves.values.flatMap { fade in
            [NativeLyricTiming.hideEnd, NativeLyricTiming.rowStart, NativeLyricTiming.rowEnd,
             NativeLyricTiming.showStart, 1].map { fade.startedAt.addingTimeInterval(NativeLyricTiming.duration * $0) }
        }
        if let rowMotion { boundaries += [rowMotion.start, rowMotion.end] }
        boundaries.append(expected)
        for boundary in Set(boundaries.filter { $0 > Date() }).sorted() {
            do { try await Task.sleep(for: .seconds(max(0, boundary.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, revision == token, identity == expectedIdentity else { return }
            if Date() >= expected {
                motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
#if FUSIONPLAY_UI_CHECKS
                LyricsReflowTextCheckEvents.transition?("end", 0)
#endif
                report("end")
                return
            }
            report(phase(at: Date()))
        }
    }

    private func phase(at now: Date) -> String {
        if let rowMotion, now >= rowMotion.start && now < rowMotion.end { return "move" }
        let fading = motion.dissolves.values.filter { $0.endsAt > now }
        if fading.contains(where: { now.timeIntervalSince($0.startedAt) < NativeLyricTiming.duration * NativeLyricTiming.hideEnd }) { return "vanish" }
        if fading.contains(where: { now.timeIntervalSince($0.startedAt) >= NativeLyricTiming.duration * NativeLyricTiming.showStart }) { return "appear" }
        if !fading.isEmpty { return "move" }
        return motion.endsAt.map { $0 > now ? "position" : "idle" } ?? "idle"
    }

    private func report(_ phase: String) {
#if FUSIONPLAY_UI_CHECKS
        guard let callback = NativeLyricsReflowCheckEvents.phase, let value = sample(phase) else { return }
        callback(value)
#endif
    }
    private func installSampler() {
#if FUSIONPLAY_UI_CHECKS
        guard NativeLyricsReflowCheckEvents.phase != nil else { return }
        NativeLyricsReflowCheckEvents.sampleOwner = checkOwner
        NativeLyricsReflowCheckEvents.sample = { sample(phase(at: Date())) }
#endif
    }
    private func removeSampler() {
#if FUSIONPLAY_UI_CHECKS
        if NativeLyricsReflowCheckEvents.sampleOwner == checkOwner {
            NativeLyricsReflowCheckEvents.sample = nil; NativeLyricsReflowCheckEvents.sampleOwner = nil
        }
#endif
    }
#if FUSIONPLAY_UI_CHECKS
    private func sample(_ phase: String) -> NativeLyricsReflowCheckEvents.Sample? {
        guard let target, let input else { return nil }
        let now = Date()
        var poses: [String: NativeLyricsReflowCheckEvents.Pose] = [:]
        var moving = 0, visible = 0
        for (key, destination) in target.positions {
            let appearance = motion.appearance(key, at: destination.origin, now: now) ?? NativeGlyphAppearance(origin: destination.origin)
            let changingLine = motion.dissolves[key].map { $0.endsAt > now } ?? false
            if changingLine { moving += 1; if appearance.opacity > 0.02 { visible += 1 } }
            let id = target.id(for: key)
            poses[id] = NativeLyricsReflowCheckEvents.Pose(id: id, origin: appearance.origin,
                frame: destination.bounds.offsetBy(dx: appearance.origin.x - destination.origin.x, dy: appearance.origin.y - destination.origin.y), opacity: appearance.opacity,
                blur: appearance.blur, lineIndex: destination.line, moving: changingLine)
        }
        let height = rowMotion?.height(at: now) ?? naturalHeight ?? target.height
        let preview = Text(verbatim: input.text).font(Font(input.font))
            .textRenderer(NativeReflowRenderer(target: target, motion: motion, now: now,
                                              overflow: min(120, max(8, input.font.pointSize * 2))))
            .lineSpacing(input.spacing).fixedSize(horizontal: false, vertical: true)
            .frame(width: input.width, alignment: .topLeading)
            .frame(height: height, alignment: .topLeading).foregroundStyle(.white)
        return NativeLyricsReflowCheckEvents.Sample(renderer: "native-text-renderer", text: input.text,
            fontName: input.font.fontName, direction: direction, phase: phase, revision: revision,
            width: input.width, height: height, targetHeight: naturalHeight ?? target.height,
            lineCount: target.lineStarts.count, nativeLayoutCount: layoutCount,
            movingClusterCount: moving, visibleMovingCount: visible, poses: poses, preview: AnyView(preview))
    }
#endif
}

private enum NativeLyricTiming {
    static let duration = 0.48
    static let hideEnd = 0.31
    static let rowStart = 0.34
    static let rowEnd = 0.64
    static let showStart = 0.68
    static let slideDuration = 0.19
}

private struct NativeLyricIdentity: Equatable {
    let text: String
    let font: String
    let traits: UInt32
    init(text: String, font: NSFont) {
        self.text = text; self.font = font.fontName; traits = font.fontDescriptor.symbolicTraits.rawValue
    }
}
private struct NativeLyricInput {
    let text: String
    let font: NSFont
    let spacing: CGFloat
    let width: CGFloat
}
private struct NativeLyricRowMotion {
    let from: CGFloat
    let target: CGFloat
    let start: Date
    let end: Date
    func height(at now: Date) -> CGFloat {
        guard now > start else { return from }
        guard now < end else { return target }
        let t = now.timeIntervalSince(start) / max(0.0001, end.timeIntervalSince(start))
        return from + (target - from) * CGFloat(t * t * (3 - 2 * t))
    }
}

@available(macOS 15.0, *)
private struct NativeGlyphLayout: Equatable {
    typealias Key = [Text.Layout.CharacterIndex]
    struct Position: Equatable {
        let origin: CGPoint
        let line: Int
        let bounds: CGRect
    }

    let identity: NativeLyricIdentity
    let width: CGFloat
    let height: CGFloat
    private let firstCharacter: Text.Layout.CharacterIndex?
    let lineStarts: [Text.Layout.CharacterIndex?]
    let lineWidths: [CGFloat]
    let positions: [Key: Position]

    init(_ layout: Text.Layout, width: CGFloat, identity: NativeLyricIdentity) {
        self.identity = identity; self.width = width
        firstCharacter = layout.flatMap { $0.flatMap { $0.characterIndices } }.min()
        let top = layout.first?.typographicBounds.rect.minY ?? 0
        let bottom = layout.map { $0.typographicBounds.rect.maxY }.max() ?? 0
        height = max(0, ceil(bottom - min(0, top)))
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
                                            line: lineIndex,
                                            bounds: slice.typographicBounds.rect.offsetBy(dx: -anchor.x, dy: -anchor.y))
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

    func id(for key: Key) -> String {
        guard let base = firstCharacter ?? key.first else { return "" }
        return key.map { String(base.distance(to: $0)) }.joined(separator: ":")
    }

    static func key(for slice: Text.Layout.RunSlice) -> Key {
        slice.characterIndices.sorted()
    }
}

private struct NativeGlyphAppearance {
    let origin: CGPoint
    var opacity: Double = 1
    var blur: CGFloat = 0
}

@available(macOS 15.0, *)
private struct NativeGlyphDissolve {
    private static let maximumBlur: CGFloat = 4
    private static let blurLead = 0.24
    let from: NativeGlyphAppearance
    let startedAt: Date
    var reposition: NativeGlyphSlide? = nil
    var endsAt: Date { startedAt.addingTimeInterval(NativeLyricTiming.duration) }

    func appearance(at destination: CGPoint, now: Date) -> NativeGlyphAppearance? {
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let progress = elapsed / NativeLyricTiming.duration
        if progress < NativeLyricTiming.hideEnd {
            let phase = progress / NativeLyricTiming.hideEnd
            let fade = Self.ease((phase - Self.blurLead) / (1 - Self.blurLead))
            let blur = from.blur + (Self.maximumBlur - from.blur) * CGFloat(Self.ease(phase))
            return NativeGlyphAppearance(origin: from.origin, opacity: from.opacity * (1 - fade), blur: blur)
        }
        if progress < NativeLyricTiming.showStart {
            return NativeGlyphAppearance(origin: destination, opacity: 0, blur: Self.maximumBlur)
        }
        guard progress < 1 else { return nil }
        let phase = Self.ease((progress - NativeLyricTiming.showStart) / (1 - NativeLyricTiming.showStart))
        return NativeGlyphAppearance(origin: reposition?.position(at: destination, now: now) ?? destination,
                                     opacity: phase, blur: Self.maximumBlur * CGFloat(1 - phase))
    }

    private static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}

private struct NativeGlyphSlide {
    let origin: CGPoint
    let startedAt: Date
    var duration: TimeInterval = NativeLyricTiming.slideDuration
    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    func position(at destination: CGPoint, now: Date) -> CGPoint {
        let remaining = 1 - min(1, max(0, now.timeIntervalSince(startedAt) / max(0.001, duration)))
        let ease = CGFloat(remaining * remaining * remaining)
        return CGPoint(x: destination.x + (origin.x - destination.x) * ease,
                       y: destination.y + (origin.y - destination.y) * ease)
    }
}

@available(macOS 15.0, *)
private struct NativeGlyphMotion {
    var dissolves: [NativeGlyphLayout.Key: NativeGlyphDissolve] = [:]
    var slides: [NativeGlyphLayout.Key: NativeGlyphSlide] = [:]

    var endsAt: Date? {
        let slideEnd = slides.values.lazy.map(\.endsAt).max()
        let dissolveEnd = dissolves.values.lazy.map(\.endsAt).max()
        if let slideEnd, let dissolveEnd { return max(slideEnd, dissolveEnd) }
        return slideEnd ?? dissolveEnd
    }

    func appearance(_ key: NativeGlyphLayout.Key, at destination: CGPoint, now: Date) -> NativeGlyphAppearance? {
        if let fading = dissolves[key]?.appearance(at: destination, now: now) { return fading }
        guard let slide = slides[key], slide.endsAt > now else { return nil }
        return NativeGlyphAppearance(origin: slide.position(at: destination, now: now))
    }

    func retarget(from previous: NativeGlyphLayout, to target: NativeGlyphLayout, now: Date, start: Date) -> Self {
        var nextDissolves: [NativeGlyphLayout.Key: NativeGlyphDissolve] = [:]
        var nextSlides: [NativeGlyphLayout.Key: NativeGlyphSlide] = [:]

        for (key, destination) in target.positions {
            guard let prior = previous.positions[key] else { continue }
            let dissolving = dissolves[key].flatMap { $0.endsAt > now ? $0 : nil }
            let sliding = slides[key].flatMap { $0.endsAt > now ? $0 : nil }
            let visible = dissolving?.appearance(at: prior.origin, now: now)?.origin
                ?? sliding?.position(at: prior.origin, now: now) ?? prior.origin
            if prior.line != destination.line {
                let from = dissolving?.appearance(at: prior.origin, now: now) ?? NativeGlyphAppearance(origin: visible)
                nextDissolves[key] = NativeGlyphDissolve(from: from, startedAt: start)
            } else if var dissolving {
                // A pixel-width update keeps the existing fade deadline. If
                // appearance is already visible, retarget its position smoothly.
                if now.timeIntervalSince(dissolving.startedAt) >= NativeLyricTiming.duration * NativeLyricTiming.showStart,
                   Self.hasDisplacement(from: visible, to: destination.origin) {
                    dissolving.reposition = NativeGlyphSlide(origin: visible, startedAt: now,
                        duration: max(0.001, min(NativeLyricTiming.slideDuration, dissolving.endsAt.timeIntervalSince(now))))
                }
                nextDissolves[key] = dissolving
            } else if Self.hasDisplacement(from: prior.origin, to: destination.origin) {
                if Self.hasDisplacement(from: visible, to: destination.origin) {
                    nextSlides[key] = NativeGlyphSlide(origin: visible, startedAt: start)
                }
            } else if let sliding {
                nextSlides[key] = sliding
            }
        }

        return NativeGlyphMotion(dissolves: nextDissolves, slides: nextSlides)
    }

    static func hasDisplacement(from origin: CGPoint, to destination: CGPoint) -> Bool {
        abs(origin.x - destination.x) >= 0.75 || abs(origin.y - destination.y) >= 0.75
    }
}

@available(macOS 15.0, *)
private struct NativeReflowRenderer: TextRenderer {
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

    let target: NativeGlyphLayout?
    let motion: NativeGlyphMotion
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
                    let key = NativeGlyphLayout.key(for: slice)
                    guard let destination = target.positions[key] else {
                        context.draw(slice)
                        continue
                    }
                    let nativeOrigin = slice.typographicBounds.origin
                    let origin = matches ? destination.origin :
                        CGPoint(x: nativeOrigin.x - anchor.x, y: nativeOrigin.y - anchor.y)
                    let animated = motion.appearance(key, at: destination.origin, now: now)
                    if animated == nil, !NativeGlyphMotion.hasDisplacement(from: origin, to: destination.origin) {
                        context.draw(slice)
                        continue
                    }
                    // Until a new measurement arrives, keep moved clusters at
                    // the previous presentation in the current text coordinate space.
                    let appearance = animated ?? NativeGlyphAppearance(origin: destination.origin)
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

#if FUSIONPLAY_UI_CHECKS
@available(macOS 15.0, *)
@MainActor enum NativeLyricsReflowCheckEvents {
    struct Pose {
        let id: String
        let origin: CGPoint
        let frame: CGRect
        let opacity: Double
        let blur: CGFloat
        let lineIndex: Int
        let moving: Bool
    }
    struct Sample {
        let renderer: String
        let text: String
        let fontName: String
        let direction: String
        let phase: String
        let revision: UInt64
        let width: CGFloat
        let height: CGFloat
        let targetHeight: CGFloat
        let lineCount: Int
        let nativeLayoutCount: Int
        let movingClusterCount: Int
        let visibleMovingCount: Int
        let poses: [String: Pose]
        let preview: AnyView
    }
    static var phase: ((Sample) -> Void)?
    static var sample: (() -> Sample?)?
    fileprivate static var sampleOwner: UUID?
}
#endif
#endif
