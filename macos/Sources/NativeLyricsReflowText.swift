import AppKit
import SwiftUI

private struct LyricsHeightManagedByRowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var lyricsHeightManagedByRow: Bool {
        get { self[LyricsHeightManagedByRowKey.self] }
        set { self[LyricsHeightManagedByRowKey.self] = newValue }
    }
}

/// Shared glyph/whole-row stages. These preserve the existing native timing.
enum LyricsNativeMotionTiming {
    static let duration = 0.48
    static let hideEnd = 0.31
    static let rowStart = 0.34
    static let rowEnd = 0.64
    static let showStart = 0.68
    static let slideDuration = 0.19
}

private struct LyricsResizeContextKey: EnvironmentKey {
    static let defaultValue = LyricsResizeContext()
}

enum LyricsResizeParticipant: Hashable { case primary, translation }
private struct LyricsResizeParticipantKey: EnvironmentKey { static let defaultValue = LyricsResizeParticipant.primary }

struct LyricsResizeGlyphPhase: Equatable {
    let timing: LyricsResizeTiming
    let hasOutgoingInk: Bool
    var hideEnd: Date { timing.start.addingTimeInterval(LyricsNativeMotionTiming.duration * LyricsNativeMotionTiming.hideEnd) }
    var rowStart: Date { timing.start.addingTimeInterval(LyricsNativeMotionTiming.duration * LyricsNativeMotionTiming.rowStart) }
    var rowEnd: Date { timing.start.addingTimeInterval(LyricsNativeMotionTiming.duration * LyricsNativeMotionTiming.rowEnd) }
}

struct LyricsResizePhaseSummary: Equatable {
    var phases: [LyricsResizeGlyphPhase] = []
    var deadline: Date? = nil
}

/// The two native texts retain their own word epochs. Row height consumes
/// their actual in-flight constraints, rather than restarting a fade window.
struct LyricsResizePhaseSnapshot {
    var phases: [LyricsResizeGlyphPhase] = []
    var deadline: Date? = nil
    var ownerCount = 0

    func heightWindow(expanding: Bool, at now: Date) -> ClosedRange<Date>? {
        let active = phases.filter { $0.timing.end > now }
        let waiting = active.filter { $0.timing.reveal > now }
        let outgoing = active.filter { $0.hasOutgoingInk && $0.hideEnd > now }
        // Growing adds safe space before the earliest incoming ink. Shrinking
        // must wait for the newest genuinely outgoing word to disappear.
        let phase = !expanding && !outgoing.isEmpty
            ? outgoing.max { $0.timing.start < $1.timing.start }
            : waiting.min { $0.timing.start < $1.timing.start }
        if let phase {
            if now < phase.rowEnd {
                let start = max(now, phase.rowStart)
                if start < phase.rowEnd { return start...phase.rowEnd }
            }
            // At t=.32 the original rowEnd (.3072) is past, but the ink is
            // still hidden until .3264. Use that gap, never another .48 wave.
            if now < phase.timing.reveal { return now...phase.timing.reveal }
        }
        if let deadline, deadline > now { return now...deadline }
        return nil
    }
}

/// Not observable: recording a native phase never republishes the view tree.
@MainActor final class LyricsResizeClock {
    private struct Owner: Equatable {
        let identity: ObjectIdentifier
        let summary: LyricsResizePhaseSummary
    }
    private var lastMeasurement: Date?
    private var owners: [LyricsResizeParticipant: Owner] = [:]
    private var rowDeadline: (owner: ObjectIdentifier, end: Date)?
    private(set) var revision: UInt64 = 0

    func timing(at now: Date, delay: TimeInterval) -> LyricsResizeTiming {
        let epoch: Date
        if let lastMeasurement, abs(now.timeIntervalSince(lastMeasurement)) < 1.0 / 60 {
            epoch = lastMeasurement
        } else { lastMeasurement = now; epoch = now }
        return LyricsResizeTiming(start: epoch.addingTimeInterval(LyricsStaggerTiming.clampSpan(delay)))
    }
    func record(_ summary: LyricsResizePhaseSummary, participant: LyricsResizeParticipant, owner: ObjectIdentifier) {
        guard summary.deadline != nil else { remove(participant: participant, owner: owner); return }
        let value = Owner(identity: owner, summary: summary)
        guard owners[participant] != value else { return }
        owners[participant] = value; revision &+= 1
    }
    func remove(participant: LyricsResizeParticipant, owner: ObjectIdentifier) {
        guard owners[participant]?.identity == owner else { return }
        owners.removeValue(forKey: participant); revision &+= 1
    }
    func snapshot(at now: Date) -> LyricsResizePhaseSnapshot {
        let summaries = owners.values.map(\.summary).filter { ($0.deadline ?? .distantPast) > now }
        return LyricsResizePhaseSnapshot(phases: summaries.flatMap(\.phases),
            deadline: summaries.compactMap(\.deadline).max(), ownerCount: summaries.count)
    }
    func recordRowDeadline(_ end: Date?, owner: ObjectIdentifier) {
        if let end { rowDeadline = (owner, end) }
        else if rowDeadline?.owner == owner { rowDeadline = nil }
    }
    func clearRowDeadline(endingAt end: Date, owner: ObjectIdentifier) {
        if rowDeadline?.owner == owner && rowDeadline?.end == end { rowDeadline = nil }
    }
    var activeDeadline: Date? {
        ([rowDeadline?.end] + owners.values.map { $0.summary.deadline }).compactMap { $0 }.max()
    }
    func reset() {
        if !owners.isEmpty { revision &+= 1 }
        owners.removeAll(); rowDeadline = nil; lastMeasurement = nil
    }
}

struct LyricsResizeTiming: Equatable {
    let start: Date
    var end: Date { start.addingTimeInterval(LyricsNativeMotionTiming.duration) }
    var reveal: Date { start.addingTimeInterval(LyricsNativeMotionTiming.duration * LyricsNativeMotionTiming.showStart) }
}

struct LyricsResizeContext {
    var isVisible = true
    var delay: TimeInterval? = nil
    var clock: LyricsResizeClock? = nil
    @MainActor func timing(at now: Date, fallbackDelay: TimeInterval) -> LyricsResizeTiming {
        let delay = LyricsStaggerTiming.clampSpan(delay ?? fallbackDelay)
        return clock?.timing(at: now, delay: delay)
            ?? LyricsResizeTiming(start: now.addingTimeInterval(delay))
    }
}

extension EnvironmentValues {
    var lyricsResizeParticipant: LyricsResizeParticipant {
        get { self[LyricsResizeParticipantKey.self] }
        set { self[LyricsResizeParticipantKey.self] = newValue }
    }
    var lyricsResizeContext: LyricsResizeContext {
        get { self[LyricsResizeContextKey.self] }
        set { self[LyricsResizeContextKey.self] = newValue }
    }
}

#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
struct NativeLyricsFreshWrapCheck {
    let fromOpacity: Double
    let initialOpacity: Double
    let startedAt: Date
    let observedAt: Date
}
@MainActor enum NativeLyricsHeightCheckEvents {
    static var measurement: ((String, CGSize, Bool) -> Void)?
    static var rowPhaseRead: ((Int, UInt64) -> Void)?
    static var freshWrap: ((NativeLyricsFreshWrapCheck) -> Void)?
}
#endif

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
    @Environment(\.lyricsHeightManagedByRow) private var heightManagedByRow
    @Environment(\.lyricsResizeContext) private var resizeContext
    @Environment(\.lyricsResizeParticipant) private var resizeParticipant
    @State private var target: NativeGlyphLayout?
    @State private var motion = NativeGlyphMotion()
    @State private var rowMotion: NativeLyricRowMotion?
    @State private var naturalHeight: CGFloat?
    @State private var naturalIdentity: NativeLyricIdentity?
    @State private var intrinsicGeometry = NativeLyricIntrinsicGeometry()
    @State private var revision: UInt64 = 0
    @State private var clock: Date?
    @State private var referencePointSize: CGFloat
    @State private var referenceFont: NSFont
#if FUSIONPLAY_UI_CHECKS
    @State private var checkOwner = UUID()
#endif

    init(text: String, font: NSFont, lineSpacing: CGFloat, reduceMotion: Bool,
         width: CGFloat, motionDelay: Double = 0) {
        self.text = text; self.font = font; self.lineSpacing = lineSpacing
        self.reduceMotion = reduceMotion; self.width = width; self.motionDelay = motionDelay
        _referencePointSize = State(initialValue: max(1, font.pointSize))
        _referenceFont = State(initialValue: font)
    }

    private var safeWidth: CGFloat { width.isFinite ? max(1, width) : 1 }
    private var allowed: Bool { !reduceMotion && !voiceOver && text.utf8.count <= 1_024 }
    private var identity: NativeLyricIdentity { NativeLyricIdentity(text: text, font: font) }
    private var end: Date? {
        if let a = motion.endsAt, let b = rowMotion?.end { return max(a, b) }
        return motion.endsAt ?? rowMotion?.end
    }

    var body: some View {
        let coordinates = NativeLyricCoordinates(font: font, width: safeWidth, referenceSize: referencePointSize, referenceFont: referenceFont)
        let currentIdentity = identity
        return TimelineView(.animation(minimumInterval: 1.0 / 60, paused: end == nil || !resizeContext.isVisible)) { context in
            renderedText(text: text, font: coordinates.font,
                renderer: NativeReflowRenderer(target: resizeContext.isVisible ? target : nil, motion: motion, now: context.date,
                    overflow: coordinates.overflow, displayScale: coordinates.scale))
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: coordinates.width, alignment: .topLeading)
                .onGeometryChange(for: NativeLyricMeasurement.self) { [currentIdentity] geometry in
                    NativeLyricMeasurement(identity: currentIdentity, size: geometry.size)
                } action: { measurement in
                    guard measurement.identity == identity else { return }
                    intrinsicGeometry.size = measurement.size
                    intrinsicGeometry.identity = measurement.identity
                    if naturalIdentity != measurement.identity { naturalIdentity = measurement.identity }
                    let topology = intrinsicGeometry.pendingTopology
                    intrinsicGeometry.pendingTopology = false
                    acceptHeight(measurement.size.height, topologyChanged: topology, at: Date(), scale: coordinates.scale)
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
                    NativeLyricsHeightCheckEvents.measurement?(text, measurement.size, heightManagedByRow)
#endif
                }
                .frame(height: physicalHeight(at: context.date, scale: coordinates.scale), alignment: .topLeading)
        }
        .frame(width: safeWidth, alignment: .topLeading)
        .contentShape(Rectangle())
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onPreferenceChange(Text.LayoutKey.self) { layouts in
            guard let native = layouts.first?.layout else { return }
            accept(NativeGlyphLayout(native, width: coordinates.width, identity: identity), coordinates: coordinates)
        }
        .onChange(of: identity) { _, _ in
            if referenceFont.fontName != font.fontName ||
               referenceFont.fontDescriptor.symbolicTraits != font.fontDescriptor.symbolicTraits {
                referenceFont = font; referencePointSize = max(1, font.pointSize)
            }
            reset(clearLayout: true)
        }
        .onChange(of: allowed) { _, enabled in if !enabled { reset(clearLayout: false) } }
        .onChange(of: heightManagedByRow) { _, managed in if managed { rowMotion = nil } }
        .onChange(of: resizeContext.isVisible) { _, visible in
            if !visible {
                motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
                resizeContext.clock?.remove(participant: resizeParticipant, owner: ObjectIdentifier(intrinsicGeometry))
            }
        }
#if FUSIONPLAY_UI_CHECKS
        // A proportional font/width change can leave native Text.Layout exactly
        // unchanged. Keep test samples in visible coordinates without asking
        // native Text to lay itself out just to update diagnostic state.
        .onChange(of: NativeLyricInput(text: text, font: font, spacing: lineSpacing, width: safeWidth)) { _, input in
            intrinsicGeometry.input = input
        }
#endif
        .onAppear { installSampler() }
        .task(id: end) { await finishMotion() }
        .onDisappear { reset(clearLayout: false); removeSampler() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func physicalHeight(at date: Date, scale: CGFloat) -> CGFloat? {
        // A new text/font identity must never inherit the old text's frame.
        // Identity is also part of the geometry payload, so equal-sized new
        // text still delivers a fresh native measurement.
        guard naturalIdentity == identity else { return nil }
        let height = heightManagedByRow ? naturalHeight : (rowMotion?.height(at: date) ?? naturalHeight)
        return height.map { $0 * scale }
    }

    private func renderedText(text: String, font: NSFont, renderer: NativeReflowRenderer) -> some View {
        Text(verbatim: text).font(Font(font)).textRenderer(renderer)
    }

    private func accept(_ measured: NativeGlyphLayout, coordinates: NativeLyricCoordinates) {
#if FUSIONPLAY_REFLOW_BENCHMARK
        NativeLyricsReflowBenchmark.hit("layoutCallbacks")
        if let prior = target, prior.width != measured.width, prior.positions == measured.positions,
           prior.lineStarts == measured.lineStarts, prior.height == measured.height, prior.identity == measured.identity {
            NativeLyricsReflowBenchmark.hit("widthOnlyCallbacks")
        }
#endif
#if FUSIONPLAY_UI_CHECKS
        intrinsicGeometry.input = NativeLyricInput(text: text, font: font, spacing: lineSpacing, width: safeWidth)
        intrinsicGeometry.layoutCount += 1
#endif
        guard target != measured else { return }
#if FUSIONPLAY_REFLOW_BENCHMARK
        NativeLyricsReflowBenchmark.hit("acceptedLayouts")
#endif
        let now = Date()
        let previous = target
        let changedWrap = previous.map { $0.lineStarts != measured.lineStarts } ?? false
        if let previous, allowed, resizeContext.isVisible,
           previous.identity == measured.identity,
           changedWrap || previous.positions != measured.positions || motion.endsAt != nil {
            let timing = resizeContext.timing(at: now, fallbackDelay: motionDelay)
            let start = timing.start
            if changedWrap {
#if FUSIONPLAY_UI_CHECKS
                intrinsicGeometry.direction = measured.height > previous.height + 0.5 ? "expand" :
                    measured.height < previous.height - 0.5 ? "contract" : "reflow"
#endif
                clock = start
            } else if end == nil {
#if FUSIONPLAY_UI_CHECKS
                intrinsicGeometry.direction = "position"
#endif
                clock = start
            }
            motion = motion.retarget(from: previous, to: measured, now: now, timing: timing, scale: coordinates.scale)
        } else {
            motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
        resizeContext.clock?.remove(participant: resizeParticipant, owner: ObjectIdentifier(intrinsicGeometry))
#if FUSIONPLAY_UI_CHECKS
            intrinsicGeometry.direction = "none"
#endif
        }
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
        motion.freshWrapChecks.forEach { NativeLyricsHeightCheckEvents.freshWrap?($0) }
#endif
        resizeContext.clock?.record(motion.phaseSummary, participant: resizeParticipant,
            owner: ObjectIdentifier(intrinsicGeometry))
        target = measured
        // Native Text's intrinsic geometry is the sole source of row height.
        // Typographic bounds below are used only to describe wrap direction.
        if changedWrap {
            intrinsicGeometry.pendingTopology = true
            if let size = intrinsicGeometry.size, intrinsicGeometry.identity == identity,
               abs(size.width - coordinates.width) * coordinates.scale < 0.75 {
                intrinsicGeometry.pendingTopology = false
                acceptHeight(size.height, topologyChanged: true, at: now, scale: coordinates.scale)
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

    private func acceptHeight(_ height: CGFloat, topologyChanged: Bool, at now: Date, scale: CGFloat) {
#if FUSIONPLAY_REFLOW_BENCHMARK
        NativeLyricsReflowBenchmark.hit("heightCallbacks")
#endif
        guard height.isFinite, height >= 0 else { return }
        if heightManagedByRow {
            // The paired original/translation row owns one height timeline.
            // Keep the physical native height, without restarting glyph tasks.
            if naturalHeight != height { naturalHeight = height }
            if rowMotion != nil { rowMotion = nil }
            return
        }
        guard let previous = naturalHeight, allowed, resizeContext.isVisible, target != nil else {
            naturalHeight = height; rowMotion = nil; return
        }
        guard topologyChanged || abs(previous - height) * scale > 0.25 else { return }
        let visible = rowMotion?.height(at: now) ?? previous
        naturalHeight = height
        if let running = rowMotion, now < running.end, !topologyChanged {
            rowMotion = NativeLyricRowMotion(from: visible, target: height,
                start: max(now, running.start), end: running.end)
        } else if topologyChanged || abs(previous - height) * scale >= max(8, font.pointSize * 0.6) {
            let start = clock ?? now.addingTimeInterval(LyricsStaggerTiming.clampSpan(motionDelay))
            rowMotion = NativeLyricRowMotion(from: visible, target: height,
                start: start.addingTimeInterval(NativeLyricTiming.duration * NativeLyricTiming.rowStart),
                end: start.addingTimeInterval(NativeLyricTiming.duration * NativeLyricTiming.rowEnd))
        } else { rowMotion = nil }
        revision &+= 1
        report("measure")
    }

    private func reset(clearLayout: Bool) {
        revision &+= 1; motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
        resizeContext.clock?.remove(participant: resizeParticipant, owner: ObjectIdentifier(intrinsicGeometry))
#if FUSIONPLAY_UI_CHECKS
        intrinsicGeometry.direction = "none"
#endif
        intrinsicGeometry.pendingTopology = false
        if clearLayout {
            if target?.identity != identity { target = nil }
            if intrinsicGeometry.identity == identity {
                naturalIdentity = identity
                naturalHeight = intrinsicGeometry.size?.height
            } else {
                naturalIdentity = nil; naturalHeight = nil
                intrinsicGeometry.size = nil
            }
#if FUSIONPLAY_UI_CHECKS
            intrinsicGeometry.input = nil
#endif
        }
#if FUSIONPLAY_UI_CHECKS
        LyricsReflowTextCheckEvents.transition?("reset", 0)
#endif
        report("reset")
    }

    private func finishMotion() async {
#if FUSIONPLAY_REFLOW_BENCHMARK
        NativeLyricsReflowBenchmark.hit("motionTasks")
#endif
        guard let expected = end else { return }
        let expectedIdentity = identity
        // A stalled main thread can start this task after its last deadline.
        // Always stop the timeline rather than retaining an expired motion.
        if expected <= Date() {
            motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
        resizeContext.clock?.remove(participant: resizeParticipant, owner: ObjectIdentifier(intrinsicGeometry))
#if FUSIONPLAY_UI_CHECKS
            LyricsReflowTextCheckEvents.transition?("end", 0)
#endif
            report("end")
            return
        }
#if FUSIONPLAY_UI_CHECKS
        // Phase sampling is a test concern. Production only needs the final
        // deadline, rather than five Date allocations for every moving glyph.
        var boundaries = motion.wrappingTransitions.flatMap { fade in
            [NativeLyricTiming.hideEnd, NativeLyricTiming.rowStart, NativeLyricTiming.rowEnd,
             NativeLyricTiming.showStart, 1].map { fade.start.addingTimeInterval(NativeLyricTiming.duration * $0) }
        }
        if let rowMotion { boundaries += [rowMotion.start, rowMotion.end] }
        boundaries.append(expected)
#if FUSIONPLAY_REFLOW_BENCHMARK
        NativeLyricsReflowBenchmark.hit("phaseBoundaries", value: Double(boundaries.count))
#endif
        for boundary in Set(boundaries.filter { $0 > Date() }).sorted() {
            do { try await Task.sleep(for: .seconds(max(0, boundary.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, end == expected, identity == expectedIdentity else { return }
            if Date() >= expected {
                motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
        resizeContext.clock?.remove(participant: resizeParticipant, owner: ObjectIdentifier(intrinsicGeometry))
#if FUSIONPLAY_UI_CHECKS
                LyricsReflowTextCheckEvents.transition?("end", 0)
#endif
                report("end")
                return
            }
            report(phase(at: Date()))
        }
#else
        do { try await Task.sleep(for: .seconds(max(0, expected.timeIntervalSinceNow))) }
        catch { return }
        guard !Task.isCancelled, end == expected, identity == expectedIdentity else { return }
        motion = NativeGlyphMotion(); rowMotion = nil; clock = nil
        resizeContext.clock?.remove(participant: resizeParticipant, owner: ObjectIdentifier(intrinsicGeometry))
#endif
    }

    private func phase(at now: Date) -> String {
        if let rowMotion, now >= rowMotion.start && now < rowMotion.end { return "move" }
        let fading = motion.wrappingTransitions.filter { $0.end > now }
        if fading.contains(where: { now.timeIntervalSince($0.start) < NativeLyricTiming.duration * NativeLyricTiming.hideEnd }) { return "vanish" }
        if fading.contains(where: { now.timeIntervalSince($0.start) >= NativeLyricTiming.duration * NativeLyricTiming.showStart }) { return "appear" }
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
        guard let target, let input = intrinsicGeometry.input else { return nil }
        let coordinates = NativeLyricCoordinates(font: input.font, width: input.width, referenceSize: referencePointSize, referenceFont: referenceFont)
        let transform = CGAffineTransform(scaleX: coordinates.scale, y: coordinates.scale)
        let now = Date()
        var poses: [String: NativeLyricsReflowCheckEvents.Pose] = [:]
        var moving = 0, visible = 0
        for (key, destination) in target.positions {
            let appearance = motion.appearance(key, at: destination.origin, now: now) ?? NativeGlyphAppearance(origin: destination.origin)
            let changingLine = motion.isWrapping(key, now: now)
            if changingLine { moving += 1; if appearance.opacity > 0.02 { visible += 1 } }
            let id = target.id(for: key)
            poses[id] = NativeLyricsReflowCheckEvents.Pose(id: id, origin: appearance.origin.applying(transform),
                frame: destination.bounds.offsetBy(dx: appearance.origin.x - destination.origin.x,
                    dy: appearance.origin.y - destination.origin.y).applying(transform),
                opacity: appearance.opacity, blur: appearance.blur, lineIndex: destination.line, moving: changingLine)
        }
        let height = rowMotion?.height(at: now) ?? naturalHeight ?? target.height
        let preview = renderedText(text: input.text, font: coordinates.font,
            renderer: NativeReflowRenderer(target: target, motion: motion, now: now,
                overflow: coordinates.overflow, displayScale: coordinates.scale))
            .lineSpacing(input.spacing).fixedSize(horizontal: false, vertical: true)
            .frame(width: coordinates.width, alignment: .topLeading)
            .frame(height: height * coordinates.scale, alignment: .topLeading)
            .frame(width: input.width, alignment: .topLeading).foregroundStyle(.white)
        return NativeLyricsReflowCheckEvents.Sample(renderer: "native-text-renderer", text: input.text,
            fontName: input.font.fontName, direction: intrinsicGeometry.direction, phase: phase, revision: revision,
            width: input.width, height: height * coordinates.scale, targetHeight: (naturalHeight ?? target.height) * coordinates.scale,
            fontPointSize: input.font.pointSize, coordinateFontPointSize: coordinates.font.pointSize, drawingScale: coordinates.scale,
            lineCount: target.lineStarts.count, nativeLayoutCount: intrinsicGeometry.layoutCount,
            movingClusterCount: moving, visibleMovingCount: visible, poses: poses, preview: AnyView(preview))
    }

#endif
}

/// Native glyph positions stay in one font coordinate system while the
/// complete text scales. No bitmap or drawingGroup is introduced; CoreText's
/// older-system raster fallback keeps rendering at its actual requested size.
@MainActor private struct NativeLyricCoordinates {
    private static let fonts: NSCache<NSFontDescriptor, NSFont> = {
        let cache = NSCache<NSFontDescriptor, NSFont>(); cache.countLimit = 64; return cache
    }()
    let font: NSFont
    let scale: CGFloat
    let width: CGFloat
    var overflow: CGFloat { min(120 / scale, max(8 / scale, font.pointSize * 2)) }

    init(font requested: NSFont, width: CGFloat, referenceSize: CGFloat, referenceFont: NSFont) {
        // Each text instance keeps its own first actual size. Translation and
        // primary rows therefore retain their native font coordinates without
        // inflating every small label to one global large font surface.
        if requested.pointSize == referenceSize { font = requested }
        else {
            // Size is part of the descriptor cache key, so two rows with the
            // same requested font but different reference sizes cannot collide.
            let descriptor = requested.fontDescriptor.withSize(referenceSize)
            // CoreText can consider a reconstructed .SFNS font equal to an
            // .AppleSystemUIFont while SwiftUI bridges/tracks them differently.
            // Reuse the original object only with exact normalized descriptor
            // equality, preserving face, traits, matrices and feature settings.
            if descriptor == referenceFont.fontDescriptor { font = referenceFont }
            else if let cached = Self.fonts.object(forKey: descriptor) { font = cached }
            else {
                font = NSFont(descriptor: descriptor, size: referenceSize)
                    ?? NSFontManager.shared.convert(requested, toSize: referenceSize)
                Self.fonts.setObject(font, forKey: descriptor)
            }
        }
        scale = max(0.01, requested.pointSize / max(1, font.pointSize))
        self.width = max(1, width / scale)
    }
}

/// Intrinsic width/topology are coordination data, not display state. Mutating
/// them must not request another Text layout for every pixel of a resize.
@MainActor private final class NativeLyricIntrinsicGeometry {
    var size: CGSize?
    var identity: NativeLyricIdentity?
    var pendingTopology = false
#if FUSIONPLAY_UI_CHECKS
    var input: NativeLyricInput?
    var layoutCount = 0
    var direction = "none"
#endif
}

private typealias NativeLyricTiming = LyricsNativeMotionTiming

private struct NativeLyricIdentity: Equatable, Sendable {
    let text: String
    let font: String
    let traits: UInt32
    init(text: String, font: NSFont) {
        self.text = text; self.font = font.fontName; traits = font.fontDescriptor.symbolicTraits.rawValue
    }
}
private struct NativeLyricMeasurement: Equatable {
    let identity: NativeLyricIdentity
    let size: CGSize
}

private struct NativeLyricInput: Equatable {
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
        return from + (target - from) * CGFloat(LyricsStaggerTiming.verticalMove.value(at: min(1, max(0, t))))
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
#if FUSIONPLAY_REFLOW_BENCHMARK
        let benchmarkStart = CFAbsoluteTimeGetCurrent()
        defer { NativeLyricsReflowBenchmark.hit("layoutParseSeconds", value: CFAbsoluteTimeGetCurrent() - benchmarkStart) }
#endif
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

    static func == (lhs: Self, rhs: Self) -> Bool {
        // The proposed canvas width can change while the actual left-aligned
        // glyph layout is identical. Do not rebuild motion or invalidate Text.
        lhs.identity == rhs.identity && lhs.height == rhs.height
            && lhs.lineStarts == rhs.lineStarts && lhs.lineWidths == rhs.lineWidths
            && lhs.positions == rhs.positions
    }

    private struct LinePair: Hashable { let old: Int; let new: Int }

    /// iPad's one-to-one native-cluster overlap mapping distinguishes a whole
    /// visual line moving down from words that actually leave their fragment.
    func continuingLines(from previous: Self) -> [Int: Int] {
        var overlap: [LinePair: Int] = [:]
        for (key, position) in positions {
            guard let prior = previous.positions[key] else { continue }
            overlap[LinePair(old: prior.line, new: position.line), default: 0] += key.count
        }
        func preferred(_ candidate: LinePair, over current: LinePair?) -> Bool {
            guard let current else { return true }
            let keepsStart = previous.lineStarts[candidate.old] == lineStarts[candidate.new]
            let currentKeepsStart = previous.lineStarts[current.old] == lineStarts[current.new]
            if keepsStart != currentKeepsStart { return keepsStart }
            let weight = overlap[candidate, default: 0], currentWeight = overlap[current, default: 0]
            if weight != currentWeight { return weight > currentWeight }
            if candidate.old != current.old { return candidate.old < current.old }
            return candidate.new < current.new
        }
        var bestFromOld: [Int: LinePair] = [:], bestFromNew: [Int: LinePair] = [:]
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
private struct NativeGlyphTransition {
    private static let maximumBlur: CGFloat = 4
    private static let blurLead = 0.24
    private static let minimumRetargetTime: TimeInterval = 0.065
    let from: NativeGlyphAppearance
    let destination: CGPoint
    let start: Date
    let end: Date
    var wrap: LyricsResizeTiming? = nil
    var hasWrapped = false

    func appearance(at now: Date) -> NativeGlyphAppearance {
        if wrap != nil {
            let progress = max(0, now.timeIntervalSince(start)) / NativeLyricTiming.duration
            if progress < NativeLyricTiming.hideEnd {
                let phase = progress / NativeLyricTiming.hideEnd
                let fade = Self.ease((phase - Self.blurLead) / (1 - Self.blurLead))
                let blur = from.blur + (Self.maximumBlur - from.blur) * CGFloat(Self.ease(phase))
                return NativeGlyphAppearance(origin: from.origin, opacity: from.opacity * (1 - fade), blur: blur)
            }
            if progress < NativeLyricTiming.showStart {
                return NativeGlyphAppearance(origin: destination, opacity: 0, blur: Self.maximumBlur)
            }
            let phase = Self.ease((progress - NativeLyricTiming.showStart) / (1 - NativeLyricTiming.showStart))
            return NativeGlyphAppearance(origin: destination, opacity: phase,
                                         blur: Self.maximumBlur * CGFloat(1 - phase))
        }
        let progress = Self.ease(now.timeIntervalSince(start) / max(0.001, end.timeIntervalSince(start)))
        let remainder = CGFloat(1 - progress)
        return NativeGlyphAppearance(origin: CGPoint(x: destination.x + (from.origin.x - destination.x) * remainder,
                                                     y: destination.y + (from.origin.y - destination.y) * remainder),
                                     opacity: 1 + (from.opacity - 1) * (1 - progress), blur: from.blur * remainder)
    }

    /// Keep outgoing ink/deadline until reveal. Afterwards preserve its exact
    /// visible pose and finish with a bounded slide, never another fade-out.
    func retarget(to next: CGPoint, at now: Date, scale: CGFloat) -> Self {
        if let wrap, now < wrap.reveal,
           NativeGlyphMotion.hasDisplacement(from: from.origin, to: next, scale: scale) {
            return Self(from: from, destination: next, start: start, end: end, wrap: wrap, hasWrapped: true)
        }
        let sample = appearance(at: now), nextStart = max(now, start)
        return Self(from: sample, destination: next, start: nextStart,
                    end: max(end, nextStart.addingTimeInterval(Self.minimumRetargetTime)), hasWrapped: hasWrapped)
    }

    private static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress)); return t * t * (3 - 2 * t)
    }
}

@available(macOS 15.0, *)
private struct NativeGlyphMotion {
    private let transitions: [NativeGlyphLayout.Key: NativeGlyphTransition]
    let endsAt: Date?
    let phaseSummary: LyricsResizePhaseSummary
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
    var freshWrapChecks: [NativeLyricsFreshWrapCheck] = []
#endif
    init(_ transitions: [NativeGlyphLayout.Key: NativeGlyphTransition] = [:]) {
        self.transitions = transitions
        endsAt = transitions.values.lazy.map(\.end).max()
        var phases: [Date: Bool] = [:]
        for transition in transitions.values {
            guard let wrap = transition.wrap else { continue }
            phases[wrap.start] = (phases[wrap.start] ?? false) || transition.from.opacity > 0.02
        }
        phaseSummary = LyricsResizePhaseSummary(phases: phases.map {
            LyricsResizeGlyphPhase(timing: LyricsResizeTiming(start: $0.key), hasOutgoingInk: $0.value)
        }.sorted { $0.timing.start < $1.timing.start }, deadline: endsAt)
    }
    var wrappingTransitions: [NativeGlyphTransition] { transitions.values.filter { $0.wrap != nil } }
    func isWrapping(_ key: NativeGlyphLayout.Key, now: Date) -> Bool {
        transitions[key].map { $0.hasWrapped && $0.end > now } ?? false
    }
    func appearance(_ key: NativeGlyphLayout.Key, at destination: CGPoint, now: Date) -> NativeGlyphAppearance? {
        guard let transition = transitions[key], transition.end > now else { return nil }
        return transition.appearance(at: now)
    }
    func retarget(from previous: NativeGlyphLayout, to target: NativeGlyphLayout, now: Date,
                  timing: LyricsResizeTiming, scale: CGFloat) -> Self {
        let continuing = target.continuingLines(from: previous)
        var next: [NativeGlyphLayout.Key: NativeGlyphTransition] = [:]
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
        var firstSamples: [NativeLyricsFreshWrapCheck] = []
#endif
        for (key, destination) in target.positions {
            guard let prior = previous.positions[key] else { continue }
            let running = transitions[key].flatMap { $0.end > now ? $0 : nil }
            if let running, running.destination == destination.origin { next[key] = running; continue }
            let crossesLine = continuing[prior.line] != destination.line
            let visible = running?.appearance(at: now) ?? NativeGlyphAppearance(origin: prior.origin)
            guard running != nil || Self.hasDisplacement(from: visible.origin, to: destination.origin, scale: scale) else { continue }
            if crossesLine, running?.hasWrapped != true {
                let transition = NativeGlyphTransition(from: visible, destination: destination.origin,
                    start: timing.start, end: timing.end, wrap: timing, hasWrapped: true)
                next[key] = transition
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
                firstSamples.append(NativeLyricsFreshWrapCheck(fromOpacity: visible.opacity,
                    initialOpacity: transition.appearance(at: now).opacity, startedAt: timing.start, observedAt: now))
#endif
            } else if let running {
                next[key] = running.retarget(to: destination.origin, at: now, scale: scale)
            } else {
                next[key] = NativeGlyphTransition(from: visible, destination: destination.origin,
                    start: timing.start, end: timing.start.addingTimeInterval(NativeLyricTiming.slideDuration))
            }
        }
#if FUSIONPLAY_LYRICS_COORDINATION_CHECKS
        var result = Self(next)
        result.freshWrapChecks = firstSamples
        return result
#else
        return Self(next)
#endif
    }
    static func hasDisplacement(from origin: CGPoint, to destination: CGPoint, scale: CGFloat = 1) -> Bool {
        abs(origin.x - destination.x) * scale >= 0.75 || abs(origin.y - destination.y) * scale >= 0.75
    }
}

@available(macOS 15.0, *)
private struct NativeReflowRenderer: TextRenderer {
    private struct GlyphDraw {
        let slice: Text.Layout.RunSlice
        let offset: CGPoint
        let opacity: Double

        func draw(in context: GraphicsContext) {
#if FUSIONPLAY_REFLOW_BENCHMARK
            NativeLyricsReflowBenchmark.hit("contextDraws")
#endif
            var ink = context
            ink.opacity *= opacity
            ink.translateBy(x: offset.x, y: offset.y)
            ink.draw(slice)
        }
    }

    private struct GlyphPaint: Equatable {
        let offset: CGPoint
        let opacity: Double
        let blurStep: Int
    }

    let target: NativeGlyphLayout?
    let motion: NativeGlyphMotion
    let now: Date
    let overflow: CGFloat
    let displayScale: CGFloat

    // Drawing padding keeps outgoing and scaled glyphs drawable without
    // changing the native text measurement.
    var displayPadding: EdgeInsets {
        guard displayScale > 1 else {
            return EdgeInsets(top: 4, leading: 0, bottom: overflow * displayScale, trailing: 0)
        }
        // Text keeps its full canonical layout. When ink grows beyond that
        // rectangle, reserve drawing-only space; never shrink/expand its text
        // measurement through sizeThatFits, which can truncate canonical lines.
        let growth = displayScale - 1
        return EdgeInsets(top: 4, leading: 0,
            bottom: overflow * displayScale + (target?.height ?? 0) * growth,
            trailing: (target?.lineWidths.max() ?? 0) * growth)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        if displayScale == 1 { drawCanonical(layout: layout, in: &context); return }
        var scaled = context
        scaled.scaleBy(x: displayScale, y: displayScale)
        drawCanonical(layout: layout, in: &scaled)
    }

    private func drawCanonical(layout: Text.Layout, in context: inout GraphicsContext) {
#if FUSIONPLAY_REFLOW_BENCHMARK
        NativeLyricsReflowBenchmark.hit("rendererDraws")
#endif
        guard let target else {
            for line in layout {
#if FUSIONPLAY_REFLOW_BENCHMARK
                NativeLyricsReflowBenchmark.hit("contextDraws")
#endif
                context.draw(line)
            }
            return
        }
        let matches = target.matches(layout)
        guard !matches || motion.endsAt != nil else {
            for line in layout {
#if FUSIONPLAY_REFLOW_BENCHMARK
                NativeLyricsReflowBenchmark.hit("contextDraws")
#endif
                context.draw(line)
            }
            return
        }
        let anchor = layout.first?.origin ?? .zero
        var blurLayers: [Int: [GlyphDraw]] = [:]
        for line in layout {
            for run in line {
                var pending: (start: Int, end: Int, paint: GlyphPaint)?
                func flush() {
                    guard let batch = pending else { return }
                    let glyph = GlyphDraw(slice: run[batch.start..<batch.end], offset: batch.paint.offset,
                                          opacity: batch.paint.opacity)
                    if batch.paint.blurStep == 0 { glyph.draw(in: context) }
                    else { blurLayers[batch.paint.blurStep, default: []].append(glyph) }
                    pending = nil
                }
                for index in run.indices {
                    let slice = run[index]
                    let key = NativeGlyphLayout.key(for: slice)
                    guard let destination = target.positions[key] else {
                        flush()
#if FUSIONPLAY_REFLOW_BENCHMARK
                        NativeLyricsReflowBenchmark.hit("contextDraws")
#endif
                        context.draw(slice)
                        continue
                    }
                    let nativeOrigin = slice.typographicBounds.origin
                    let origin = matches ? destination.origin :
                        CGPoint(x: nativeOrigin.x - anchor.x, y: nativeOrigin.y - anchor.y)
                    let animated = motion.appearance(key, at: destination.origin, now: now)
                    let paint: GlyphPaint
                    if animated == nil, !NativeGlyphMotion.hasDisplacement(from: origin, to: destination.origin, scale: displayScale) {
                        paint = GlyphPaint(offset: .zero, opacity: 1, blurStep: 0)
                    } else {
                        // Keep the original shaped run. Combining adjacent
                        // slices with identical paint does not reshape ligatures,
                        // change stacking order, or quantize their positions.
                        let appearance = animated ?? NativeGlyphAppearance(origin: destination.origin)
                        guard appearance.opacity > 0 else { flush(); continue }
                        paint = GlyphPaint(offset: CGPoint(x: appearance.origin.x - origin.x,
                                                          y: appearance.origin.y - origin.y),
                                           opacity: appearance.opacity,
                                           blurStep: Int((appearance.blur * 4).rounded()))
                    }
                    if let batch = pending, batch.end == index, batch.paint == paint {
                        pending = (batch.start, index + 1, paint)
                    } else {
                        flush()
                        pending = (index, index + 1, paint)
                    }
                }
                flush()
            }
        }
        for (step, glyphs) in blurLayers.sorted(by: { $0.key < $1.key }) {
#if FUSIONPLAY_REFLOW_BENCHMARK
            NativeLyricsReflowBenchmark.hit("blurLayers")
#endif
            var filtered = context
            filtered.addFilter(.blur(radius: CGFloat(step) / (4 * displayScale)))
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
        let fontPointSize: CGFloat
        let coordinateFontPointSize: CGFloat
        let drawingScale: CGFloat
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

#if FUSIONPLAY_REFLOW_BENCHMARK
/// Diagnostic counters exist only in the isolated performance executable.
enum NativeLyricsReflowBenchmark {
    private final class Counts: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Double] = [:]
    }
    private static let counts = Counts()
    static func hit(_ key: String, value: Double = 1) {
        counts.lock.lock(); counts.values[key, default: 0] += value; counts.lock.unlock()
    }
    static func reset() { counts.lock.lock(); counts.values.removeAll(keepingCapacity: true); counts.lock.unlock() }
    static func snapshot() -> [String: Double] { counts.lock.lock(); defer { counts.lock.unlock() }; return counts.values }
}
#endif
