import AppKit
import SwiftUI

@MainActor private final class RowCoordinationFixture: ObservableObject {
    @Published var width: CGFloat = 520
    @Published var original = "Keep the quiet words together while the winding river moves across the mountains and the sea"
    @Published var translation = "清晨的光逐渐洒向远方，风吹过山川和海洋，新的故事正在发生"
    @Published var shown = true
    @Published var reduced = false
    @Published var voiceOver = false
    @Published var fontSize: CGFloat = 28
    @Published var delay: Double = 0
    @Published var visible = true
    @Published var spacing: CGFloat = 2
    @Published var translationFirst = false
    @Published var actualVisibility = false
    @Published var rowOffset: CGFloat = 0
    let resizeClock = LyricsResizeClock()
    var actualSize: CGSize = .zero
}

private struct RowCoordinationFixtureView: View {
    @ObservedObject var state: RowCoordinationFixture
    var body: some View {
        Group {
            if state.shown {
                let identity = LyricsRowContentIdentity(text: state.original, translation: state.translation)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.translationFirst ? [LyricsResizeParticipant.translation, .primary] : [.primary, .translation], id: \.self) { participant in
                        if participant == .primary {
                            if state.original.isEmpty {
                                Text("•••").font(.system(size: state.fontSize))
                            } else {
                                LyricsReflowText(text: state.original,
                                    font: .monospacedSystemFont(ofSize: state.fontSize, weight: .bold),
                                    lineSpacing: state.spacing, reduceMotion: state.reduced, width: state.width)
                                    .environment(\.lyricsResizeParticipant, .primary)
                            }
                        } else if !state.translation.isEmpty {
                            LyricsReflowText(text: state.translation,
                                font: .systemFont(ofSize: state.fontSize * 0.60, weight: .semibold),
                                lineSpacing: 0, reduceMotion: state.reduced, width: state.width)
                                .environment(\.lyricsResizeParticipant, .translation)
                        }
                    }
                }
                .frame(width: state.width, alignment: .topLeading)
                .modifier(LyricsRowHeightMotion(identity: identity, wrapThreshold: state.fontSize * 0.45,
                    stagesEnabled: state.original.utf8.count <= 1_024 && state.translation.utf8.count <= 1_024,
                    checkReduceMotion: state.reduced, checkVoiceOver: state.voiceOver))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { state.actualSize = $0 }
                .environment(\.lyricsRowMotionDelay, state.delay)
                .modifier(RowFixtureResizeContext(state: state))
                .offset(y: state.rowOffset)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "fixture.lyrics.viewport")
    }
}

private struct RowFixtureResizeContext: ViewModifier {
    @ObservedObject var state: RowCoordinationFixture
    @ViewBuilder func body(content: Content) -> some View {
        if state.actualVisibility {
            content.modifier(LyricsResizeVisibility(viewport: "fixture.lyrics.viewport",
                viewportSize: CGSize(width: 720, height: 800), presentationActive: true))
        } else {
            content.environment(\.lyricsResizeContext, LyricsResizeContext(isVisible: state.visible,
                delay: state.delay, clock: state.resizeClock))
        }
    }
}

private final class RowCoordinationPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@main struct LyricsRowCoordinationSmoke {
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "LyricsRowCoordination", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("FAIL: lyric coordination check timed out\n".utf8)); exit(124)
        }
        Task { @MainActor in
            do { try pureChecks(); try await nativeChecks(); print("PASS: continuous viewport metrics, one staged bilingual height, actual first-visibility wrap, same-sized identity changes, CJK, rapid resize, real offscreen settling, shared epoch/owner orders, t=.20/.32 continuation, fresh-word opacity, same-line slides, empty/hidden return, scale, reduced motion and VoiceOver; strictly offscreen, no images/input"); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }

    @MainActor private static func pureChecks() throws {
        let sharedClock = LyricsResizeClock()
        let epoch = Date(timeIntervalSinceReferenceDate: 100)
        let firstTiming = sharedClock.timing(at: epoch, delay: 1)
        let pairedTiming = sharedClock.timing(at: epoch.addingTimeInterval(0.01), delay: 1)
        try require(firstTiming == pairedTiming && abs(firstTiming.start.timeIntervalSince(epoch) - 1) < 0.0001,
                    "Paired native/height callbacks lost a shared epoch or full 1000ms setting")
        let nextFrame = sharedClock.timing(at: epoch.addingTimeInterval(0.02), delay: 1)
        try require(nextFrame.start > firstTiming.start, "Resize clock retained an expired frame epoch")
        let key = LyricsRowContentIdentity(text: "phase", translation: "阶段")
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        let oldPhase = LyricsResizeGlyphPhase(timing: LyricsResizeTiming(start: base), hasOutgoingInk: true)
        let oldPlan = LyricsResizePhaseSnapshot(phases: [oldPhase], deadline: oldPhase.timing.end, ownerCount: 1)
        for offset in [0.20, 0.32] {
            var height = LyricsRowHeightCoordinator()
            height.observe(LyricsRowMeasurement(identity: key, size: CGSize(width: 500, height: 80)),
                at: base, delay: 0, wrapThreshold: 14)
            height.observe(LyricsRowMeasurement(identity: key, size: CGSize(width: 300, height: 140)),
                at: base, delay: 0, wrapThreshold: 14, phaseSnapshot: oldPlan)
            let now = base.addingTimeInterval(offset)
            let current = height.height(for: key, at: now)!
            height.observe(LyricsRowMeasurement(identity: key, size: CGSize(width: 360, height: 100)),
                at: now, delay: 0, wrapThreshold: 14, phaseSnapshot: oldPlan)
            let motion = height.motion!
            let expectedEnd = base.addingTimeInterval(offset < 0.30 ? 0.48 * 0.64 : 0.48 * 0.68)
            try require(abs(motion.end.timeIntervalSince(expectedEnd)) < 0.0001 && motion.start >= now,
                        "Continuation t=\(offset) restarted its row phase")
            try require(abs(height.height(for: key, at: now)! - current) < 0.0001,
                        "Continuation reused a past start and jumped visible height")
        }
        let freshPhase = LyricsResizeGlyphPhase(timing: LyricsResizeTiming(start: base.addingTimeInterval(0.20)), hasOutgoingInk: true)
        let merged = LyricsResizePhaseSnapshot(phases: [oldPhase, freshPhase], deadline: freshPhase.timing.end, ownerCount: 2)
        let now = base.addingTimeInterval(0.20)
        let growWindow = merged.heightWindow(expanding: true, at: now)!
        let shrinkWindow = merged.heightWindow(expanding: false, at: now)!
        try require(growWindow.upperBound <= oldPhase.timing.reveal
            && shrinkWindow.lowerBound >= freshPhase.hideEnd && shrinkWindow.upperBound <= freshPhase.timing.reveal,
                    "Fresh outgoing words were clipped or old incoming ink lost its expansion space")
        let primary = NSObject(), translation = NSObject(), replacement = NSObject()
        var windows: [ClosedRange<Date>] = []
        for reverse in [false, true] {
            let clock = LyricsResizeClock()
            let first = LyricsResizePhaseSummary(phases: [oldPhase], deadline: oldPhase.timing.end)
            let second = LyricsResizePhaseSummary(phases: [freshPhase], deadline: freshPhase.timing.end)
            if reverse {
                clock.record(second, participant: .translation, owner: ObjectIdentifier(translation))
                clock.record(first, participant: .primary, owner: ObjectIdentifier(primary))
            } else {
                clock.record(first, participant: .primary, owner: ObjectIdentifier(primary))
                clock.record(second, participant: .translation, owner: ObjectIdentifier(translation))
            }
            try require(clock.snapshot(at: now).ownerCount == 2, "Clock did not merge both native owners")
            windows.append(clock.snapshot(at: now).heightWindow(expanding: false, at: now)!)
            clock.record(first, participant: .primary, owner: ObjectIdentifier(replacement))
            clock.remove(participant: .primary, owner: ObjectIdentifier(primary))
            try require(clock.snapshot(at: now).ownerCount == 2, "Old teardown removed a replacement owner")
        }
        try require(windows[0] == windows[1], "Native callback order changed the height phase")
        for width in stride(from: CGFloat(200), through: 800, by: 0.25) {
            let a = LyricsRowMetrics(width: width), b = LyricsRowMetrics(width: width + 0.25)
            try require((20...34).contains(a.fontSize) && b.fontSize >= a.fontSize, "Viewport font exceeded supported range")
            try require(abs(a.fontSize - b.fontSize) <= 0.019 && abs(a.rowSpacing - b.rowSpacing) < 0.01,
                        "Viewport metrics contain a hard mode jump")
            for scale in [0.75, 1.0, 2.0] {
                try require((a.fontSize * scale).isFinite && abs(a.fontSize * scale * 0.60 / (a.fontSize * scale) - 0.60) < 0.001,
                            "User font scale/translation ratio changed")
            }
        }
        let first = LyricsRowContentIdentity(text: "First", translation: "第一行")
        let second = LyricsRowContentIdentity(text: "Other", translation: "另一行")
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var state = LyricsRowHeightCoordinator()
        state.observe(LyricsRowMeasurement(identity: first, size: CGSize(width: 500, height: 80)), at: start, delay: 0, wrapThreshold: 14)
        state.observe(LyricsRowMeasurement(identity: first, size: CGSize(width: 300, height: 140)), at: start, delay: 0.24, wrapThreshold: 14)
        guard let grow = state.motion else { throw NSError(domain: "No row growth", code: 1) }
        try require(abs(grow.start.timeIntervalSince(start) - (0.24 + 0.48 * 0.34)) < 0.0001,
                    "Whole-row growth does not match glyph disappearance/delay")
        try require(abs(grow.end.timeIntervalSince(start) - (0.24 + 0.48 * 0.64)) < 0.0001,
                    "Whole-row growth does not finish before glyph appearance")
        try require(grow.height(at: grow.start) == 80 && grow.height(at: grow.end) == 140, "Row endpoint mismatch")
        let middle = grow.start.addingTimeInterval(grow.end.timeIntervalSince(grow.start) * 0.5)
        let visible = grow.height(at: middle)
        state.observe(LyricsRowMeasurement(identity: first, size: CGSize(width: 520, height: 75)), at: middle, delay: 1, wrapThreshold: 14)
        try require(abs((state.height(for: first, at: middle) ?? 0) - visible) < 0.0001, "Rapid reverse jumped the row height")
        try require((state.motion?.end.timeIntervalSince(middle) ?? 0) > 1, "Full 1000ms stagger was lost")
        state.observe(LyricsRowMeasurement(identity: second, size: CGSize(width: 520, height: 75)), at: middle, delay: 0, wrapThreshold: 14)
        try require(state.motion == nil && state.height(for: second, at: middle) == 75 && state.height(for: first, at: middle) == nil,
                    "A new identity inherited previous row motion/height")
        state.observe(LyricsRowMeasurement(identity: second, size: CGSize(width: 510, height: 75)), at: middle, delay: 0, wrapThreshold: 14)
        try require(state.motion == nil, "Width-only measurement started a height timeline")
        state.observe(LyricsRowMeasurement(identity: second, size: CGSize(width: 300, height: 150)),
            at: middle, delay: 1, wrapThreshold: 14, isVisible: false)
        try require(state.motion == nil && state.height(for: second, at: middle) == 150,
                    "Offscreen row animated or stopped updating its true content height")
    }

    @MainActor private static func nativeChecks() async throws {
        guard #available(macOS 15, *) else { print("SKIP: native checks require macOS 15; pure policy checks passed"); return }
        let state = RowCoordinationFixture()
        state.actualVisibility = true; state.rowOffset = 1_600
        var measurements: [(String, CGSize, Bool)] = []
        var phaseReads: [Int] = []
        var freshSamples: [NativeLyricsFreshWrapCheck] = []
        NativeLyricsHeightCheckEvents.measurement = { measurements.append(($0, $1, $2)) }
        NativeLyricsHeightCheckEvents.rowPhaseRead = { count, _ in phaseReads.append(count) }
        NativeLyricsHeightCheckEvents.freshWrap = { freshSamples.append($0) }
        defer {
            NativeLyricsHeightCheckEvents.measurement = nil
            NativeLyricsHeightCheckEvents.rowPhaseRead = nil
            NativeLyricsHeightCheckEvents.freshWrap = nil
        }
        let host = NSHostingView(rootView: RowCoordinationFixtureView(state: state))
        let window = RowCoordinationPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 800),
            styleMask: [.nonactivatingPanel, .titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true; window.contentView = host
        defer { window.contentView = nil; window.close() }
        @MainActor func pump(_ seconds: Double = 0.05) async throws {
            let end = Date().addingTimeInterval(seconds)
            repeat {
                host.needsLayout = true; host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            } while Date() < end
            try require(!window.isVisible && !window.isKeyWindow && !window.isMainWindow && window.alphaValue == 0,
                        "Test window became visible")
            try require(NSApp.activationPolicy() == .prohibited && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
                        "Test took foreground")
            try require(state.actualSize.height.isFinite && state.actualSize.height > 0, "Invalid actual row height")
        }
        try await pump(0.2)
        NativeLyricsReflowBenchmark.reset()
        state.width = 480; try await pump(0.06)
        try require((NativeLyricsReflowBenchmark.snapshot()["motionTasks"] ?? 0) == 0,
                    "Actual initially offscreen row retained a glyph timeline")
        state.rowOffset = 0; try await pump(0.12)
        let firstVisibleHeight = state.actualSize.height
        phaseReads.removeAll(); state.width = 300; try await pump(0.075)
        try require(abs(state.actualSize.height - firstVisibleHeight) < 0.5,
                    "Actual false-to-true visibility lost the first visible wrap baseline")
        try require(phaseReads.contains(2), "Real visibility did not enable both native word-phase owners")
        try await pump(0.6)
        state.actualVisibility = false; state.width = 520; try await pump(0.2)
        try require(measurements.contains { $0.0 == state.original && $0.2 }
            && measurements.contains { $0.0 == state.translation && $0.2 }, "Both native texts did not defer height to the row")
        for translationFirst in [false, true] {
            state.translationFirst = translationFirst; state.width = 520
            try await pump(0.7)
            let before = state.actualSize.height
            phaseReads.removeAll(); state.width = 300
            try await pump(0.075)
            try require(abs(state.actualSize.height - before) < 0.5,
                        "Paired callbacks lost their original batch width or moved before the fade stage")
            try require(phaseReads.contains(2), "Queued row apply did not read both native owner summaries")
            try await pump(0.6)
        }
        state.translationFirst = false; state.width = 520; try await pump(0.7)
        let wide = state.actualSize.height
        state.width = 300
        try await pump(0.7)
        try require(state.actualSize.height > wide, "Narrowing did not grow the actual bilingual row")
        for width in [CGFloat(410), 330, 520, 290, 480, 300] { state.width = width; try await pump(0.025) }
        try await pump(0.7)
        let settled = state.actualSize.height
        try await pump(0.12)
        try require(abs(state.actualSize.height - settled) < 0.5, "Settled row restarted its own height motion")
        // An already-initialized row may get its new hidden geometry in the
        // same turn that visibility returns. Cancelling that queued batch must
        // synchronize the latest target rather than keep its old static height.
        state.width = 300; try await pump(0.7)
        let knownNarrowHeight = state.actualSize.height
        state.width = 520; try await pump(0.7)
        state.visible = false; try await pump(0.08)
        state.width = 300; host.needsLayout = true; host.layoutSubtreeIfNeeded()
        state.visible = true; try await pump(0.7)
        try require(abs(state.actualSize.height - knownNarrowHeight) < 0.5,
                    "Visible return discarded a pending new height and kept the old static height")
        state.visible = false
        try await pump(0.12)
        NativeLyricsReflowBenchmark.reset()
        for width in [CGFloat(420), 280, 500, 320] { state.width = width; try await pump(0.03) }
        let hiddenCounters = NativeLyricsReflowBenchmark.snapshot()
        try require((hiddenCounters["acceptedLayouts"] ?? 0) > 0 && (hiddenCounters["motionTasks"] ?? 0) == 0,
                    "Offscreen native text failed to update statically or retained a timeline")
        state.visible = true; try await pump(0.08)
        try require((NativeLyricsReflowBenchmark.snapshot()["motionTasks"] ?? 0) == 0,
                    "Returning to visible text replayed an old reflow")
        state.width = 330; state.translation = ""; try await pump(0.7)
        NativeLyricsReflowBenchmark.reset()
        state.spacing += 0.25; try await pump(0.08)
        let slideCounters = NativeLyricsReflowBenchmark.snapshot()
        try require((slideCounters["acceptedLayouts"] ?? 0) > 0 && (slideCounters["motionTasks"] ?? 0) > 0
            && (slideCounters["blurLayers"] ?? 0) == 0,
                    "Actual same-line glyph movement was removed or turned into a wrap fade")
        try await pump(0.6)
        state.width = 620; state.translation = ""; try await pump(0.7)
        state.width = 330; try await pump(0.20)
        freshSamples.removeAll(); state.width = 410; try await pump(0.035)
        try require(!freshSamples.isEmpty, "Fresh-word continuation fixture did not actually cross new native clusters")
        try require(freshSamples.allSatisfy { $0.initialOpacity + 0.00001 >= $0.fromOpacity },
                    "A new wrapped word inherited an old epoch and instantly disappeared")
        try await pump(0.6)
        state.original = "ABCD"; state.translation = ""; state.width = 520
        try await pump(0.12)
        guard let originalSize = measurements.last(where: { $0.0 == "ABCD" })?.1 else {
            throw NSError(domain: "No native first identity measurement", code: 1)
        }
        state.original = "WXYZ"
        try await pump(0.12)
        guard let newSize = measurements.last(where: { $0.0 == "WXYZ" })?.1 else {
            throw NSError(domain: "Equal-sized new text never received a fresh native identity measurement", code: 1)
        }
        try require(abs(newSize.height - originalSize.height) < 0.5, "Equal-size fixture unexpectedly changed height")
        NativeLyricsReflowBenchmark.reset()
        for width in [CGFloat(519), 518, 517] { state.width = width; try await pump(0.025) }
        try require((NativeLyricsReflowBenchmark.snapshot()["motionTasks"] ?? 0) == 0,
                    "An unchanged single-line layout started a glyph timeline")
        state.original = "中文歌词测试，风吹过山川和海洋"; state.translation = "A translation kept together"
        try await pump(0.12)
        try require(measurements.contains { $0.0 == state.original }, "CJK native measurement missing")
        state.fontSize = 56; try await pump(0.15)
        let large = state.actualSize.height
        state.fontSize = 21; try await pump(0.7)
        try require(large > state.actualSize.height, "User 200%/75% native font scaling was lost")
        state.shown = false; try await pump(0.02)
        state.shown = true; try await pump(0.15)
        state.original = ""; try await pump(0.1)
        state.reduced = true; measurements.removeAll(); state.original = "Reduced motion still shows real lyrics"
        try await pump(0.12)
        try require(measurements.contains { !$0.2 }, "Reduced motion retained the row animation owner")
        state.reduced = false; state.voiceOver = true; measurements.removeAll(); state.original = "VoiceOver keeps a readable sentence"
        try await pump(0.12)
        try require(measurements.contains { !$0.2 }, "VoiceOver retained the row animation owner")
        print("Native geometry deliveries: \(measurements.count); no screenshot/render bitmap or OS accessibility setting changes")
    }
}
