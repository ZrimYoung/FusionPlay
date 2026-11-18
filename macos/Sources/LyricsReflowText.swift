import AppKit
import SwiftUI

/// macOS 15 uses the native TextRenderer implementation shared in behavior with
/// FusionPlay iPad. macOS 14 keeps the existing CoreText fallback.
@MainActor
struct LyricsReflowText: View {
    let text: String
    let font: NSFont
    let lineSpacing: CGFloat
    let reduceMotion: Bool
    let width: CGFloat
    var motionDelay: Double = 0
    @Environment(\.lyricsRowMotionDelay) private var rowMotionDelay
    private var effectiveMotionDelay: Double {
        LyricsStaggerTiming.clampSpan(motionDelay > 0 ? motionDelay : rowMotionDelay)
    }

    typealias Layout = LyricsWordLayout
    // The conservative bound also covers the older-system fallback.
    static let transitionDuration: Double = 0.56
    static func measure(text: String, font: NSFont, lineSpacing: CGFloat, width: CGFloat) -> Layout {
        LyricsWordLayout.measure(text: text, font: font, lineSpacing: lineSpacing, width: width)
    }
    private var useNativeRenderer: Bool {
#if FUSIONPLAY_UI_CHECKS
        return !LyricsReflowTextCheckEvents.forceLegacyRenderer
#else
        return true
#endif
    }
    var body: some View {
#if FUSIONPLAY_UI_CHECKS
        content.onChange(of: effectiveMotionDelay, initial: true) { _, delay in
            LyricsReflowTextCheckEvents.inputDelay?(text, delay)
        }
#else
        content
#endif
    }
    @ViewBuilder private var content: some View {
        if text.utf8.count > 1_024 {
            Text(verbatim: text).font(Font(font)).lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width.isFinite ? max(1, width) : 1, alignment: .topLeading)
                .accessibilityLabel(text)
        } else {
#if compiler(>=6.0)
        if #available(macOS 15.0, *), useNativeRenderer {
            NativeLyricsReflowText(text: text, font: font, lineSpacing: lineSpacing,
                                  reduceMotion: reduceMotion, width: width, motionDelay: effectiveMotionDelay)
        } else { fallback }
#else
        fallback
#endif
        }
    }
    private var fallback: some View {
        CoreTextLyricsReflowText(text: text, font: font, lineSpacing: lineSpacing,
                                reduceMotion: reduceMotion, width: width, motionDelay: effectiveMotionDelay)
    }
}

/// A retained canvas of shaped word fragments. Width changes move words in
/// place; words that change lines disappear before their drawing is replaced.
@MainActor
private struct CoreTextLyricsReflowText: View {
    let text: String
    let font: NSFont
    let lineSpacing: CGFloat
    let reduceMotion: Bool
    let width: CGFloat
    var motionDelay: Double = 0

    typealias Layout = LyricsWordLayout
    static let transitionDuration: Double = 0.56
    private static let vanishDuration: Double = 0.16
    private static let moveDuration: Double = 0.20
    private static let appearDuration: Double = 0.20
    nonisolated private static let hiddenBlur: CGFloat = 9

    static func measure(text: String, font: NSFont, lineSpacing: CGFloat, width: CGFloat) -> Layout {
        LyricsWordLayout.measure(text: text, font: font, lineSpacing: lineSpacing, width: width)
    }

    private struct Identity: Equatable {
        let text: String
        let face: String
        let traits: UInt32
        init(_ layout: Layout) {
            text = layout.text; face = layout.font.fontName
            traits = layout.font.fontDescriptor.symbolicTraits.rawValue
        }
    }

    private struct WordKey: Hashable {
        let location: Int
        let length: Int
        init(_ range: NSRange) { location = range.location; length = range.length }
    }

    private struct Sprite: Identifiable {
        let fragment: Layout.Fragment
        var frame: CGRect
        var opacity: Double
        var blur: CGFloat
        var id: String { fragment.id }
        var word: WordKey { WordKey(fragment.wordRange) }
        init(_ fragment: Layout.Fragment, visible: Bool = true) {
            self.fragment = fragment; frame = fragment.frame
            opacity = visible ? 1 : 0; blur = visible ? 0 : CoreTextLyricsReflowText.hiddenBlur
        }
        init(fragment: Layout.Fragment, frame: CGRect, opacity: Double, blur: CGFloat) {
            self.fragment = fragment; self.frame = frame; self.opacity = opacity; self.blur = blur
        }
    }

    private struct Presentation {
        var height: CGFloat
        var sprites: [Sprite]
        init(_ layout: Layout) { height = layout.height; sprites = layout.fragments.map { Sprite($0) } }
        init(height: CGFloat, sprites: [Sprite]) { self.height = height; self.sprites = sprites }
    }

    private struct Stage {
        let phase: String
        let start: TimeInterval
        let end: TimeInterval
        let from: Presentation
        let to: Presentation

        func sample(_ now: TimeInterval) -> Presentation {
            let amount = min(1, max(0, (now - start) / max(0.0001, end - start)))
            let t = amount * amount * (3 - 2 * amount)
            let target = Dictionary(uniqueKeysWithValues: to.sprites.map { ($0.id, $0) })
            let sprites = from.sprites.map { source -> Sprite in
                guard let destination = target[source.id] else { return source }
                return Sprite(fragment: t < 1 ? source.fragment : destination.fragment,
                              frame: CGRect(x: source.frame.minX + (destination.frame.minX - source.frame.minX) * t,
                                            y: source.frame.minY + (destination.frame.minY - source.frame.minY) * t,
                                            width: source.frame.width + (destination.frame.width - source.frame.width) * t,
                                            height: source.frame.height + (destination.frame.height - source.frame.height) * t),
                              opacity: source.opacity + (destination.opacity - source.opacity) * t,
                              blur: source.blur + (destination.blur - source.blur) * t)
            }
            return Presentation(height: from.height + (to.height - from.height) * t, sprites: sprites)
        }
    }

    private struct Plan {
        let revision: UInt64
        let identity: Identity
        let direction: String
        let reportsTransition: Bool
        let affected: Set<WordKey>
        var target: Layout
        var stages: [Stage]
        var end: TimeInterval { stages.last?.end ?? 0 }
        func stage(at now: TimeInterval) -> Stage? {
            stages.first(where: { now < $0.end }) ?? stages.last
        }
        func sample(_ now: TimeInterval) -> Presentation {
            stage(at: now)?.sample(now) ?? Presentation(target)
        }
    }

    @State private var settled: Layout?
    @State private var plan: Plan?
    @State private var revision: UInt64 = 0
#if FUSIONPLAY_UI_CHECKS
    @State private var checkOwner = UUID()
#endif

    var body: some View {
        let requested = Self.measure(text: text, font: font, lineSpacing: lineSpacing, width: width)
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: plan == nil)) { _ in
            let layout = plan?.target ?? settled ?? requested
            let presentation = plan?.sample(ProcessInfo.processInfo.systemUptime) ?? Presentation(layout)
            Group {
                if layout.isRasterComplete {
                    SpriteCanvas(presentation: presentation, width: layout.width)
                } else {
                    // Very long text or a failed bitmap allocation still has a
                    // complete accessible and visible fallback.
                    Text(layout.text).font(Font(layout.font))
                        .lineSpacing(layout.lineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
                }
            }
        }
        // The canvas computes presentation values itself. An inherited row
        // animation must not animate those values a second time.
        .transaction { transaction in transaction.animation = nil; transaction.disablesAnimations = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .onAppear {
            synchronize(requested, animated: false)
            installCheckSampler()
        }
        .onChange(of: requested) { _, next in synchronize(next, animated: !reduceMotion) }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { synchronize(requested, animated: false) }
        }
        .task(id: revision) { await finishPlan() }
        .onDisappear {
            synchronize(plan?.target ?? settled ?? requested, animated: false)
            removeCheckSampler()
        }
    }

    private struct SpriteCanvas: View {
        let presentation: Presentation
        let width: CGFloat
        var body: some View {
            ZStack(alignment: .topLeading) {
                ForEach(presentation.sprites) { sprite in
                    if let image = sprite.fragment.image {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: max(0, sprite.frame.width), height: max(0, sprite.frame.height))
                            .blur(radius: sprite.blur)
                            .opacity(sprite.opacity)
                            .position(x: sprite.frame.midX, y: sprite.frame.midY)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
            .frame(width: width, height: max(0, presentation.height), alignment: .topLeading)
        }
    }

    private func synchronize(_ next: Layout, animated: Bool) {
        let previous = plan?.target ?? settled
        guard let previous, animated, previous.isRasterComplete, next.isRasterComplete,
              Identity(previous) == Identity(next) else {
            revision &+= 1
            settled = next; plan = nil
            reportTransition("reset")
            reportPhase("reset", layout: next)
            return
        }
        guard previous != next else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let active = plan, active.target.lineEnds == next.lineEnds, now < active.end {
            // Pixel-by-pixel resizing inside the same wrap only changes the
            // destinations. Keep each phase's original deadline.
            plan = Self.retarget(active, to: next, now: now)
            reportPhase("retarget")
            return
        }

        let active = plan.flatMap { now < $0.end ? $0 : nil }
        let actual = active?.sample(now) ?? Presentation(previous)
        var affected = Self.affectedWords(from: actual, to: next)
        if let active { affected.formUnion(active.affected) }
        let hasWrap = previous.lineEnds != next.lineEnds
        let hasMovement = actual.height != next.height || Self.positionsDiffer(actual, next)
        guard hasWrap || !affected.isEmpty || hasMovement else {
            settled = next; plan = nil
            return
        }
        revision &+= 1
        let direction: String
        if affected.isEmpty && !hasWrap { direction = "position" }
        else if next.height > actual.height + 0.5 { direction = "expand" }
        else if next.height < actual.height - 0.5 { direction = "contract" }
        else { direction = "reflow" }
        let durations: [(String, Double)]
        if direction == "position" { durations = [("move", Self.moveDuration)] }
        else if direction == "expand" {
            durations = [("move", Self.moveDuration), ("appear", Self.appearDuration)]
        } else {
            durations = [("vanish", Self.vanishDuration), ("move", Self.moveDuration), ("appear", Self.appearDuration)]
        }
        var cursor = now + LyricsStaggerTiming.clampSpan(motionDelay)
        let times = durations.map { phase, duration -> (String, TimeInterval, TimeInterval) in
            defer { cursor += duration }
            return (phase, cursor, cursor + duration)
        }
        let base = Self.addHiddenDestinations(to: actual, target: next)
        let stages = Self.stages(from: base, target: next, affected: affected,
                                 direction: direction, times: times)
        plan = Plan(revision: revision, identity: Identity(next), direction: direction,
                    reportsTransition: hasWrap, affected: affected, target: next, stages: stages)
        if hasWrap { reportTransition("begin") }
        reportPhase("begin")
        if let phase = stages.first?.phase { reportPhase(phase) }
    }

    private static func positionsDiffer(_ actual: Presentation, _ next: Layout) -> Bool {
        let positions = Dictionary(uniqueKeysWithValues: actual.sprites.map { ($0.id, $0.frame) })
        return next.fragments.contains { positions[$0.id] != $0.frame }
    }

    private static func affectedWords(from actual: Presentation, to next: Layout) -> Set<WordKey> {
        let old = Dictionary(grouping: actual.sprites, by: \.word)
        let new = Dictionary(grouping: next.fragments, by: { WordKey($0.wordRange) })
        var result = Set<WordKey>()
        for word in Set(old.keys).union(new.keys) {
            let before = old[word] ?? []
            let after = new[word] ?? []
            if before.count != after.count { result.insert(word); continue }
            let previous = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0.fragment) })
            if after.contains(where: { fragment in
                guard let previous = previous[fragment.id] else { return true }
                return previous.lineIndex != fragment.lineIndex || previous.sourceRange != fragment.sourceRange
            }) { result.insert(word) }
        }
        return result
    }

    private static func addHiddenDestinations(to state: Presentation, target: Layout) -> Presentation {
        let ids = Set(target.fragments.map(\.id))
        // Old fragments which have already vanished need not accumulate during
        // an interrupted long-word reflow.
        var sprites = state.sprites.filter { $0.opacity > 0.001 || ids.contains($0.id) }
        let existing = Set(sprites.map(\.id))
        sprites += target.fragments.filter { !existing.contains($0.id) }.map { Sprite($0, visible: false) }
        return Presentation(height: state.height, sprites: sprites)
    }

    private static func hideAffected(_ state: Presentation, affected: Set<WordKey>) -> Presentation {
        Presentation(height: state.height, sprites: state.sprites.map { sprite in
            guard affected.contains(sprite.word) else { return sprite }
            var result = sprite; result.opacity = 0; result.blur = hiddenBlur
            return result
        })
    }

    private static func placeHidden(_ state: Presentation, target: Layout,
                                    affected: Set<WordKey>) -> Presentation {
        let fragments = Dictionary(uniqueKeysWithValues: target.fragments.map { ($0.id, $0) })
        return Presentation(height: state.height, sprites: state.sprites.map { sprite in
            guard affected.contains(sprite.word), let destination = fragments[sprite.id] else { return sprite }
            return Sprite(fragment: destination, frame: destination.frame, opacity: 0, blur: hiddenBlur)
        })
    }

    private static func moveGoal(_ state: Presentation, target: Layout, affected: Set<WordKey>,
                                 holdAffected: Bool) -> Presentation {
        let fragments = Dictionary(uniqueKeysWithValues: target.fragments.map { ($0.id, $0) })
        return Presentation(height: target.height, sprites: state.sprites.map { sprite in
            guard let destination = fragments[sprite.id] else {
                var removed = sprite; removed.opacity = 0; removed.blur = hiddenBlur; return removed
            }
            if affected.contains(sprite.word) {
                return Sprite(fragment: holdAffected ? sprite.fragment : destination,
                              frame: holdAffected ? sprite.frame : destination.frame,
                              opacity: 0, blur: hiddenBlur)
            }
            return Sprite(fragment: sprite.fragment, frame: destination.frame, opacity: 1, blur: 0)
        })
    }

    private static func visibleGoal(_ state: Presentation, target: Layout) -> Presentation {
        let fragments = Dictionary(uniqueKeysWithValues: target.fragments.map { ($0.id, $0) })
        return Presentation(height: target.height, sprites: state.sprites.map { sprite in
            guard let destination = fragments[sprite.id] else {
                var removed = sprite; removed.opacity = 0; removed.blur = hiddenBlur; return removed
            }
            return Sprite(destination)
        })
    }

    private static func stages(from initial: Presentation, target: Layout, affected: Set<WordKey>,
                               direction: String, times: [(String, TimeInterval, TimeInterval)]) -> [Stage] {
        var state = initial
        var result: [Stage] = []
        for (phase, start, end) in times {
            let goal: Presentation
            switch phase {
            case "vanish": goal = hideAffected(state, affected: affected)
            case "move":
                if direction == "contract" || direction == "reflow" {
                    state = placeHidden(state, target: target, affected: affected)
                }
                goal = moveGoal(state, target: target, affected: affected, holdAffected: direction == "expand")
            default:
                // Retargeting an already visible appearance keeps its current
                // opacity. A newly entered appearance swaps only hidden ink.
                let hasVisibleMovingInk = state.sprites.contains { affected.contains($0.word) && $0.opacity > 0.001 }
                if !hasVisibleMovingInk { state = placeHidden(state, target: target, affected: affected) }
                goal = visibleGoal(state, target: target)
            }
            result.append(Stage(phase: phase, start: start, end: end, from: state, to: goal))
            state = goal
        }
        return result
    }

    private static func retarget(_ active: Plan, to target: Layout, now: TimeInterval) -> Plan {
        let remaining = active.stages.filter { $0.end > now }
            .map { ($0.phase, max(now, $0.start), $0.end) }
        var result = active
        result.target = target
        result.stages = stages(from: addHiddenDestinations(to: active.sample(now), target: target),
                               target: target, affected: active.affected, direction: active.direction, times: remaining)
        return result
    }

    private func finishPlan() async {
        guard let initial = plan else { return }
        let token = initial.revision
        let identity = initial.identity
        let boundaries = initial.stages.map(\.end)
        for (index, boundary) in boundaries.enumerated() {
            let delay = max(0, boundary - ProcessInfo.processInfo.systemUptime)
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled, revision == token, let active = plan,
                  active.revision == token, active.identity == identity else { return }
            if index == boundaries.count - 1 {
                // Render exactly the measured final layout and pause the clock.
                settled = active.target; plan = nil
                if active.reportsTransition { reportTransition("end") }
                reportPhase("end", finished: active)
            } else if let phase = active.stage(at: boundary + 0.00001)?.phase {
                reportPhase(phase)
            }
        }
    }

    private func reportTransition(_ event: String) {
#if FUSIONPLAY_UI_CHECKS
        LyricsReflowTextCheckEvents.transition?(event, plan == nil ? 0 : 1)
#endif
    }

    private func reportPhase(_ phase: String, layout: Layout? = nil, finished: Plan? = nil) {
#if FUSIONPLAY_UI_CHECKS
        guard let callback = LyricsReflowTextCheckEvents.phase,
              let sample = checkSample(phase, layout: layout, finished: finished) else { return }
        callback(sample)
#endif
    }

    private func installCheckSampler() {
#if FUSIONPLAY_UI_CHECKS
        guard LyricsReflowTextCheckEvents.phase != nil else { return }
        LyricsReflowTextCheckEvents.sampleOwner = checkOwner
        LyricsReflowTextCheckEvents.sample = { checkSample("sample") }
#endif
    }

    private func removeCheckSampler() {
#if FUSIONPLAY_UI_CHECKS
        if LyricsReflowTextCheckEvents.sampleOwner == checkOwner {
            LyricsReflowTextCheckEvents.sample = nil
            LyricsReflowTextCheckEvents.sampleOwner = nil
        }
#endif
    }

#if FUSIONPLAY_UI_CHECKS
    private func checkSample(_ phase: String, layout explicit: Layout? = nil,
                             finished: Plan? = nil) -> LyricsReflowTextCheckEvents.PhaseSample? {
        let active = plan ?? finished
        guard let layout = explicit ?? active?.target ?? settled else { return nil }
        let presentation = plan?.sample(ProcessInfo.processInfo.systemUptime) ?? Presentation(layout)
        let affected = active?.affected ?? []
        let poses = Dictionary(uniqueKeysWithValues: presentation.sprites.map { sprite in
            (sprite.id, LyricsReflowTextCheckEvents.WordPose(frame: sprite.frame, opacity: sprite.opacity,
                blur: sprite.blur, lineIndex: sprite.fragment.lineIndex, wordRange: sprite.fragment.wordRange,
                sourceRange: sprite.fragment.sourceRange, moving: affected.contains(sprite.word)))
        })
        let visible = Set(presentation.sprites.filter { affected.contains($0.word) && $0.opacity > 0.02 }.map(\.word))
        return LyricsReflowTextCheckEvents.PhaseSample(text: layout.text, direction: active?.direction ?? "none",
            phase: phase, revision: active?.revision ?? revision, width: layout.width,
            height: presentation.height, targetHeight: layout.height, movingWordCount: affected.count,
            visibleMovingCount: visible.count, poses: poses,
            preview: AnyView(SpriteCanvas(presentation: presentation, width: layout.width)))
    }
#endif
}

#if FUSIONPLAY_UI_CHECKS
@MainActor enum LyricsReflowTextCheckEvents {
    struct WordPose {
        let frame: CGRect
        let opacity: Double
        let blur: CGFloat
        let lineIndex: Int
        let wordRange: NSRange
        let sourceRange: NSRange
        let moving: Bool
    }
    struct PhaseSample {
        let text: String
        let direction: String
        let phase: String
        let revision: UInt64
        let width: CGFloat
        let height: CGFloat
        let targetHeight: CGFloat
        let movingWordCount: Int
        let visibleMovingCount: Int
        let poses: [String: WordPose]
        let preview: AnyView
    }
    static var forceLegacyRenderer = false
    static var inputDelay: ((String, Double) -> Void)?
    static var transition: ((String, Int) -> Void)?
    static var phase: ((PhaseSample) -> Void)?
    static var sample: (() -> PhaseSample?)?
    fileprivate static var sampleOwner: UUID?
}
#endif
