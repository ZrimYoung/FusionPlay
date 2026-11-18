import AppKit
import SwiftUI

@main struct LyricsViewportAnchorSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
    @MainActor private static func run() async throws {
        let baseline = ProcessInfo.processInfo.environment["FUSIONPLAY_ANCHOR_BASELINE"] == "1"
        let maximum = ProcessInfo.processInfo.environment["FUSIONPLAY_ANCHOR_MAXIMUM"] == "1"
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        UserDefaults.standard.setVolatileDomain([
            "appLanguage": "en", "uiFontFamily": "", "uiFontWeight": 400,
            "staggerLyricMotion": true, "lyricStaggerMilliseconds": maximum ? 1_000 : 140,
            "lyricLineMoveMilliseconds": maximum ? 1_500 : 420, "lyricsFontScalePercent": maximum ? 200 : 100
        ], forName: UserDefaults.argumentDomain)
        var source = ""
        for index in 0..<70 {
            let t = index * 6
            source += String(format: "[%02d:%02d]", t / 60, t % 60)
                + "A quiet morning brings another changing light across the mountains and the sea \(index)\n"
            source += String(format: "[%02d:%02d]", t / 60, t % 60)
                + "清晨的光逐渐洒向远方，风吹过山川和海洋 \(index)\n"
        }
        let document = LyricsDocument(source)
        var position: UInt64 = 124_000
        func fixture(voiceOver: Bool = false) -> some View {
            LyricsView(document: document, positionMs: position, loading: false,
                       connected: true, compact: false, canSeek: true, seek: { _ in },
                       checkReduceMotion: false, checkVoiceOver: voiceOver)
                .appTypography().environment(\.colorScheme, .dark)
        }
        let host = NSHostingView(rootView: fixture())
        let window = AnchorCheckPanel(contentRect: NSRect(x: 50, y: 50, width: 680, height: 620),
                              styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func viewport() -> NSScrollView? { descendants(host).compactMap { $0 as? NSScrollView }.first }
        func row(_ id: Int) -> LyricsRowGeometryCheckView? {
            descendants(host).compactMap { $0 as? LyricsRowGeometryCheckView }.first { $0.lineID == id }
        }
        var samples: [[String: Any]] = []
        var readingPoint: (id: Int, rowFraction: CGFloat, viewportFraction: CGFloat)?
        func record(_ stage: String, id: Int) -> Double? {
            host.layoutSubtreeIfNeeded()
            guard let scroll = viewport(), let marker = row(id) else {
                samples.append(["stage": stage, "row": id, "missing": true]); return nil
            }
            let clip = scroll.contentView
            let rect = marker.convert(marker.bounds, to: clip)
            let top = clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
            let anchor = top + rect.height * 0.32
            let target = clip.bounds.height * 0.32
            let error = Double(anchor - target)
            samples.append(["stage": stage, "row": id, "width": clip.bounds.width,
                            "height": clip.bounds.height, "rowTop": top, "rowHeight": rect.height,
                            "anchorError": error, "originY": clip.bounds.minY,
                            "readingPointDrift": readingPoint.map {
                                Double(top + rect.height * $0.rowFraction - clip.bounds.height * $0.viewportFraction)
                            } as Any])
            return error
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "LyricsViewportAnchor", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        await pause(1)
        let activeID = document.lines[document.activeLineIndex(at: position)!].id
        let initial = record("initial", id: activeID)
        var follows: [(String, Int, Bool)] = []
        var finishedAnchors: [(Int?, Bool)] = []
        LyricsViewCheckEvents.follow = { follows.append(($0, $1, $2)) }
        LyricsViewCheckEvents.anchorFinished = { finishedAnchors.append(($0, $1)) }
        defer { LyricsViewCheckEvents.follow = nil; LyricsViewCheckEvents.anchorFinished = nil }
        guard let scroll = viewport() else { throw NSError(domain: "Missing lyric viewport", code: 1) }
        let scrollID = ObjectIdentifier(scroll)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        await pause(0.05)
        readingPoint = row(activeID)?.anchor?.heldReadingPoint
        for width: CGFloat in [640, 560, 470, 390, 330, 470, 620, 760, 540] {
            window.setContentSize(NSSize(width: width, height: 620))
            for tick in 0..<4 {
                await pause(0.03)
                _ = record("resize-\(Int(width))-\(tick)", id: activeID)
            }
        }
        await pause(0.75)
        let held = record("held-resize", id: activeID)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        var settleErrors: [Double] = []
        for tick in 0..<100 {
            await pause(0.025)
            if let value = record("settle-\(tick)", id: activeID) { settleErrors.append(value) }
        }
        let final = record("settled", id: activeID)
        let viewportFollows = follows.filter { $0.0 == "viewport" }
        let settleDrift = samples.filter { ($0["stage"] as? String)?.hasPrefix("settle") == true }
            .compactMap { $0["readingPointDrift"] as? Double }
        print("Measured active row: initial=\(initial ?? .nan), held=\(held ?? .nan), final=\(final ?? .nan), max settling=\(settleErrors.map(abs).max() ?? .nan), viewport follows=\(viewportFollows.count)")
        try require(viewport().map(ObjectIdentifier.init) == scrollID, "Resizing recreated the native lyric scroll view")
        try require(window.alphaValue == 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                    "Hidden fixture changed the foreground app")
        if !baseline {
            try require(!settleDrift.isEmpty && settleDrift.allSatisfy { abs($0) <= 1 },
                        "The same sentence's visible reading point drifted during resize settling")
            try require(viewportFollows.isEmpty, "The same focused sentence was needlessly animated back after resizing")
        }

        if !maximum {
            // Playback advances while resizing: preserve the old reading point
            // during reflow, then follow the latest sentence exactly once.
            follows.removeAll()
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            await pause(0.05)
            window.setContentSize(NSSize(width: 390, height: 620)); await pause(0.12)
            position = 130_000
            host.rootView = fixture()
            await pause(0.12)
            window.setContentSize(NSSize(width: 610, height: 620)); await pause(0.16)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            let latestID = document.lines[document.activeLineIndex(at: position)!].id
            let deadline = Date().addingTimeInterval(4)
            while follows.filter({ $0.0 == "viewport" }).isEmpty, Date() < deadline { await pause(0.025) }
            await pause(0.6)
            readingPoint = nil
            _ = record("advanced-during-resize", id: latestID)
            try require(follows.filter { $0.0 == "viewport" }.map { $0.1 } == [latestID],
                        "Resize did not follow latest sentence \(latestID) once: follows=\(follows), finishes=\(finishedAnchors)")
            guard let last = samples.last, let latestTop = last["rowTop"] as? CGFloat,
                  let latestHeight = last["rowHeight"] as? CGFloat else {
                let markers = descendants(host).compactMap { $0 as? LyricsViewportRowView }.map { $0.lineID }
                throw NSError(domain: "Missing latest lyric", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Latest \(latestID) missing; rows=\(markers), follows=\(follows), bounds=\(scroll.contentView.bounds), document=\(String(describing: scroll.documentView?.frame))"])
            }
            try require(latestTop < 350 && latestTop + latestHeight > 0, "Latest playback sentence remained outside the viewport")

            // Preserve a manual reading point, without recentering on playback.
            descendants(host).compactMap { $0 as? LyricsActivityCheckDriving }.first?.beginBrowsingForCheck()
            await pause(0.05)
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: scroll.contentView.bounds.minY + 170))
            scroll.reflectScrolledClipView(scroll.contentView)
            await pause(0.1)
            follows.removeAll()
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            await pause(0.05)
            readingPoint = descendants(host).compactMap { $0 as? LyricsViewportRowView }.first?.anchor?.heldReadingPoint
            try require(readingPoint != nil, "Manual reading position was not captured")
            window.setContentSize(NSSize(width: 430, height: 620)); await pause(0.25)
            window.setContentSize(NSSize(width: 580, height: 620)); await pause(0.2)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            await pause(1.2)
            _ = record("manual-reading", id: readingPoint!.id)
            try require(follows.isEmpty, "Resizing interrupted manual lyric browsing")
            try require((samples.last?["readingPointDrift"] as? Double).map { abs($0) <= 1 } ?? false,
                        "Manual reading point moved during horizontal reflow")

            // VoiceOver keeps ownership of native accessibility scrolling.
            host.rootView = fixture(voiceOver: true)
            await pause(0.1)
            follows.removeAll(); readingPoint = nil
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            await pause(0.05)
            try require(descendants(host).compactMap { $0 as? LyricsViewportRowView }.first?.anchor?.isHolding == false,
                        "Native anchoring overrode VoiceOver's reading position")
            window.setContentSize(NSSize(width: 420, height: 620)); await pause(0.2)
            window.setContentSize(NSSize(width: 600, height: 620)); await pause(0.2)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            await pause(1.2)
            try require(follows.isEmpty, "Resize issued a follow while VoiceOver owned the reading position")
        }
        let result: [String: Any] = ["baseline": baseline, "maximum": maximum,
            "initialError": initial as Any, "heldError": held as Any, "finalError": final as Any,
            "maxSettlingReadingPointDrift": settleDrift.map(abs).max() ?? 0,
            "viewportFollowCountForSameSentence": viewportFollows.count, "samples": samples,
            "receiverStarted": false, "realPreferencesChanged": false,
            "visibleTestWindows": false, "originalForegroundProcess": originalFrontmost ?? 0]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print(baseline ? "BASELINE: native row/viewport geometry recorded without screenshots" : "PASS: focused lyric remains anchored during horizontal reflow; latest playback, manual browsing and VoiceOver ownership preserved (nonactivating hidden panel, maximum=\(maximum))")
    }
}

private final class AnchorCheckPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
