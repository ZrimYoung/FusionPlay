import AppKit
import SwiftUI

@MainActor private final class HeightState: ObservableObject {
    @Published var height: CGFloat = 340
    @Published var interacting = false
    @Published var position: UInt64 = 124_000
    @Published var voiceOver = false
}

private struct HeightFixture: View {
    @ObservedObject var state: HeightState
    let document: LyricsDocument
    private func lyrics(active: Bool) -> some View {
        LyricsView(document: document, positionMs: state.position, loading: false,
            connected: true, compact: true, canSeek: true, presentationActive: active,
            geometryInteractionActive: active && state.interacting, seek: { _ in },
            checkReduceMotion: false, checkVoiceOver: state.voiceOver)
            .appTypography().environment(\.colorScheme, .dark)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Color.clear.frame(height: 80)
                lyrics(active: true).frame(height: state.height)
                Spacer(minLength: 0)
            }.frame(width: 420, height: 700, alignment: .top)
            lyrics(active: false).frame(width: 420, height: 700)
        }.frame(width: 840, height: 700, alignment: .leading)
            .frame(width: 420, height: 700, alignment: .leading).clipped()
    }
}

@main struct LyricsViewportHeightSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor private static func run() async throws {
        let baseline = ProcessInfo.processInfo.environment["FUSIONPLAY_HEIGHT_BASELINE"] == "1"
        UserDefaults.standard.setVolatileDomain(["appLanguage": "en", "uiFontFamily": "", "uiFontWeight": 400,
            "staggerLyricMotion": true, "lyricStaggerMilliseconds": 140,
            "lyricLineMoveMilliseconds": 420, "lyricsFontScalePercent": 100], forName: UserDefaults.argumentDomain)
        var source = ""
        for i in 0..<70 {
            source += String(format: "[%02d:%02d]", i * 6 / 60, i * 6 % 60)
                + "A quiet morning brings another light across the sea \(i)\n"
        }
        let document = LyricsDocument(source), state = HeightState()
        let host = NSHostingView(rootView: HeightFixture(state: state, document: document))
        let window = NSPanel(contentRect: NSRect(x: 50, y: 50, width: 420, height: 700),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func scrolls() -> [NSScrollView] { descendants(host).compactMap { $0 as? NSScrollView } }
        func primary() -> NSScrollView? {
            scrolls().min { $0.convert($0.bounds, to: nil).midX < $1.convert($1.bounds, to: nil).midX }
        }
        func marker(_ id: Int) -> LyricsViewportRowView? {
            guard let scroll = primary() else { return nil }
            return descendants(scroll).compactMap { $0 as? LyricsViewportRowView }.first { $0.lineID == id }
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "LyricsViewportHeight", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        await pause(1)
        guard let scroll = primary() else { throw NSError(domain: "Missing primary scroll", code: 1) }
        let originalScroll = ObjectIdentifier(scroll)
        let id = document.lines[document.activeLineIndex(at: state.position)!].id
        var follows: [(String, Int, Bool)] = [], samples: [[String: Any]] = []
        LyricsViewCheckEvents.follow = { follows.append(($0, $1, $2)) }
        defer { LyricsViewCheckEvents.follow = nil }
        state.interacting = true; await pause(0.08)
        var point = marker(id)?.anchor?.heldReadingPoint
        func record(_ stage: String) {
            host.layoutSubtreeIfNeeded()
            guard let marker = marker(id), let owner = marker.anchor else {
                samples.append(["stage": stage, "requestedHeight": state.height, "missing": true]); return
            }
            if point == nil { point = owner.heldReadingPoint }
            let clip = scroll.contentView, rect = marker.convert(marker.bounds, to: clip)
            let top = clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
            let drift = point.map { Double(top + rect.height * $0.rowFraction - clip.bounds.height * $0.viewportFraction) }
            samples.append(["stage": stage, "requestedHeight": state.height, "height": clip.bounds.height,
                "rowTop": top, "rowHeight": rect.height, "origin": clip.bounds.minY,
                "drift": drift as Any, "bindingChanges": owner.bindingChangesForCheck,
                "correctBinding": owner.boundScrollForCheck === scroll,
                "scrollIdentity": String(describing: ObjectIdentifier(scroll))])
        }
        record("start")
        for (phase, heights) in [("shrink", stride(from: 330.0, through: 20, by: -10).map { $0 }),
                                  ("grow", stride(from: 30.0, through: 380, by: 10).map { $0 })] {
            for (tick, height) in heights.enumerated() {
                state.height = height
                record("\(phase)-\(tick)-immediate")
                await pause(0.008); record("\(phase)-\(tick)-mid")
                await pause(0.008); record("\(phase)-\(tick)-end")
            }
        }
        state.interacting = false
        for tick in 0..<100 { await pause(0.02); record("settle-\(tick)") }
        let drifts = samples.compactMap { $0["drift"] as? Double }
        let incorrectBindings = samples.filter { $0["correctBinding"] as? Bool == false }.count
        let sameLineFollows = follows.count
        let summary: [String: Any] = ["baseline": baseline, "maximumDrift": drifts.map(abs).max() ?? 0,
            "incorrectBindings": incorrectBindings, "followCountForSameLine": sameLineFollows, "samples": samples]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("HEIGHT: max drift=\(drifts.map(abs).max() ?? .nan), incorrect bindings=\(incorrectBindings), same-line follows=\(sameLineFollows), sample count=\(samples.count)")
        if !baseline {
            try require(primary().map(ObjectIdentifier.init) == originalScroll, "Height interaction recreated its native viewport")
            try require(incorrectBindings == 0, "A lyric anchor switched to the other mounted page's viewport")
            try require(sameLineFollows == 0, "Height interaction issued a second scrollTo for the same sentence")
            try require(!drifts.isEmpty && drifts.allSatisfy { abs($0) <= 1.5 }, "Height interaction visibly moved its held reading point")
        }
        // Ordinary playback must still advance after geometry ownership ends.
        follows.removeAll(); state.position = 130_000
        await pause(0.8)
        let latest = document.lines[document.activeLineIndex(at: state.position)!].id
        if !baseline { try require(follows.filter { $0.0 == "playback" }.map { $0.1 } == [latest], "Playback follow did not resume after height interaction") }
        print(baseline ? "BASELINE: height geometry recorded" : "PASS: custom height interaction, unique viewport ownership, no delayed same-line follow, normal playback resumes")
    }
}
