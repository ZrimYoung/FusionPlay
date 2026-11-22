import AppKit
import Darwin
import SwiftUI

@MainActor private final class CanvasPerformanceClock { var time: TimeInterval = 10_000 }
private final class CanvasPerformancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Real production PlayerView; only the receiver and the canvas clock are fixtures.
/// Its window is never ordered. The one warm-up bitmap stays in memory and is
/// excluded from every measurement; measured ticks perform native layout only.
@main struct PlayerCanvasPerformanceSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("FAIL: canvas performance check timed out\n".utf8)); exit(124)
        }
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }

    private static func cpu() -> Double {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PlayerCanvasPerformance", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw failure(message) }
    }
    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))] * 1_000
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private static func run() async throws {
        let domain = "tech.zrim.fusionplay.canvas-performance-check"
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == domain,
              let rootPath = env["FUSIONPLAY_CANVAS_PERF_ROOT"],
              let outputPath = env["FUSIONPLAY_CANVAS_PERF_OUTPUT"],
              let manifestPath = env["FUSIONPLAY_CANVAS_PERF_MANIFEST"] else {
            throw failure("Unexpected isolated test environment")
        }
        let root = URL(fileURLWithPath: rootPath)
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        let manifest = try JSONSerialization.jsonObject(with: manifestData)
        let defaults = UserDefaults.standard
        defaults.setVolatileDomain([
            "appLanguage": "en", NarrowPlayerLayout.storageKey: NarrowPlayerLayout.ipadPaged.rawValue,
            LyricsDisplayMode.storageKey: LyricsDisplayMode.automatic.rawValue,
            "playerControlsAlwaysVisible": true, "playerWindowPinned": false,
            "playerShowsPinButton": false, "playerShowsLyricsButton": true,
            "wrapPlayerMetadata": false, "coverLyricsExpandedByDragging": false,
            "lyricsPageShowsArtwork": true, "lyricsPageShowsTrackInfo": true,
            "uiFontFamily": "", "uiFontWeight": 400,
            "staggerLyricMotion": true, "lyricStaggerMilliseconds": 140,
            "lyricLineMoveMilliseconds": 420, "lyricsFontScalePercent": 100,
            "playerShowsTransport": true, "playerShowsProgress": true,
            "coverPlayerShowsTransport": true, "coverPlayerShowsProgress": true,
            "albumPlayerShowsTransport": true, "albumPlayerShowsProgress": true
        ], forName: UserDefaults.argumentDomain)
        let lyrics = (0..<12).map { index in
            let stamp = String(format: "[%02d:%02d]", index * 6 / 60, index * 6 % 60)
            return stamp + "A quiet morning brings another changing light across the mountains and the sea \(index)\n"
                + stamp + "清晨的光逐渐洒向远方，风吹过山川和海洋，新的故事正在发生 \(index)"
        }.joined(separator: "\n")
        // A paused, connected media snapshot holds the active sentence constant
        // while preserving all native playback/lyrics UI and staged animations.
        let state = Snapshot(phase: .paused, title: "SYNTHETIC CANVAS PERFORMANCE TITLE",
            artist: "SYNTHETIC ARTIST", album: "SYNTHETIC ALBUM", trackId: "canvas-performance-fixture",
            artworkUrl: "", lyricsText: lyrics, durationMs: 180_000, positionMs: 36_000,
            controlsAvailable: true, volume: 50, message: "", address: "", output: "", queueMs: 0,
            outputLatencyMs: 0, scheduleErrorMs: 0, underruns: 0, droppedFrames: 0, resyncs: 0)
        let artwork = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor(srgbRed: 0.35, green: 0.2, blue: 0.6, alpha: 1).setFill(); rect.fill(); return true
        }
        let model = ReceiverModel.preview(state, artwork: artwork, root: root)
        let clock = CanvasPerformanceClock()
        let motion = PlayerResponsiveMotionDriver(automaticallyTicks: false, now: { clock.time })
        let host = NSHostingView(rootView: PlayerView(model: model, responsiveMotion: motion).appTypography())
        let window = CanvasPerformancePanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true; window.contentView = host
        defer { motion.stop(); window.contentView = nil; window.close() }
        func isolated() throws {
            try require(!window.isVisible && !window.isKeyWindow && !window.isMainWindow && window.alphaValue == 0,
                        "Test window became visible/key/main")
            try require(NSApp.activationPolicy() == .prohibited,
                        "Test changed application activation policy")
            try require(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "Test took foreground")
        }
        @MainActor func pump() async {
            host.needsLayout = true; host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
        }
        @MainActor func settle(size: NSSize, page: CompactPlayerPage = .playback) async throws {
            window.setContentSize(size)
            await pump()
            if let coordinator = host.gestureRecognizers.compactMap({ $0.target as? NarrowPlayerHorizontalScroll.Coordinator }).first {
                coordinator.requestPage(page)
            }
            for _ in 0..<4 { await pump() }
            clock.time += 2; motion.advance(to: clock.time)
            for _ in 0..<3 { await pump() }
            try await Task.sleep(for: .milliseconds(800))
            await pump()
            try isolated()
            try require(motion.pose != nil && !motion.isAnimating && !motion.hasScheduledTimer, "Canvas did not settle")
        }
        await pump()
        try await Task.sleep(for: .milliseconds(180))
        await pump()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        } else { throw failure("Cannot initialize offscreen native text layout") }
        let warmupCounters = NativeLyricsReflowBenchmark.snapshot()
        try await settle(size: NSSize(width: 760, height: 720))
        try require(descendants(host).contains { $0 is LyricsRowGeometryCheckView }, "No actual lyric row probes")
        var results: [[String: Any]] = []
        for scenario in ["continuous-width", "mode-spring", "page-spring"] {
            try await settle(size: NSSize(width: scenario == "page-spring" ? 520 : 760, height: 720))
            guard let coordinator = host.gestureRecognizers.compactMap({ $0.target as? NarrowPlayerHorizontalScroll.Coordinator }).first else {
                throw failure("No production paging coordinator")
            }
            let rows = descendants(host).compactMap { $0 as? LyricsRowGeometryCheckView }
            let originalScrolls = Set(rows.compactMap { $0.enclosingScrollView }.map(ObjectIdentifier.init))
            var clipEvents = 0
            let tokens = descendants(host).compactMap { $0 as? NSScrollView }.map { scroll -> NSObjectProtocol in
                let clip = scroll.contentView; clip.postsBoundsChangedNotifications = true
                return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                    object: clip, queue: .main) { _ in clipEvents += 1 }
            }
            NativeLyricsReflowBenchmark.reset()
            let tickCount = 60
            var work: [Double] = []
            let startCPU = cpu(), startWall = ProcessInfo.processInfo.systemUptime
            let startClock = clock.time
            var movingTicks = 0
            for tick in 0..<tickCount {
                let begin = ProcessInfo.processInfo.systemUptime
                clock.time = startClock + Double(tick + 1) / 60
                switch scenario {
                case "continuous-width":
                    let phase = Double(tick) / Double(tickCount - 1)
                    let triangle = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                    window.setContentSize(NSSize(width: 760 - 280 * triangle, height: 720))
                case "mode-spring":
                    if tick == 0 { window.setContentSize(NSSize(width: 520, height: 720)) }
                default:
                    if tick == 0 { coordinator.requestPage(.lyrics) }
                    if tick == 30 { coordinator.requestPage(.playback) }
                }
                await pump()
                motion.advance(to: clock.time)
                if motion.isAnimating { movingTicks += 1 }
                await pump()
                work.append(ProcessInfo.processInfo.systemUptime - begin)
            }
            let workCPU = cpu() - startCPU
            let wall = ProcessInfo.processInfo.systemUptime - startWall
            let counters = NativeLyricsReflowBenchmark.snapshot()
            tokens.forEach(NotificationCenter.default.removeObserver)
            try isolated()
            let nowScrolls = Set(descendants(host).compactMap { $0 as? LyricsRowGeometryCheckView }
                .compactMap { $0.enclosingScrollView }.map(ObjectIdentifier.init))
            try require(originalScrolls == nowScrolls && nowScrolls.count == 1, "Lyric viewport recreated during \(scenario)")
            try require(movingTicks > 0, "No real canvas animation in \(scenario)")
            let result: [String: Any] = [
                "scenario": scenario, "ticks": tickCount, "fakeClockStepSeconds": 1.0 / 60,
                "cpuSeconds": workCPU, "wallSeconds": wall,
                "workP50ms": percentile(work, 0.5), "workP95ms": percentile(work, 0.95),
                "workMaxms": (work.max() ?? 0) * 1_000,
                "workOver16ms": work.filter { $0 > 1.0 / 60 }.count,
                "movingTicks": movingTicks, "clipBoundsChanges": clipEvents, "counters": counters,
                "nativeLayoutCallbacksObserved": (counters["layoutCallbacks"] ?? 0) > 0,
                "lyricViewportRetained": true
            ]
            results.append(result)
            print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
        }
        let output: [String: Any] = [
            "schema": 1, "manifest": manifest, "scenarios": results, "warmupCounters": warmupCounters,
            "fixture": "full production PlayerView, 12 bilingual lines, paused at 36s, connected preview receiver",
            "measurement": "process CPU and main-thread native layout work; fake canvas clock, no compositor FPS claim; CoreText internals are not instrumented",
            "visibleWindows": false, "orderedWindows": false, "systemInputPosted": false,
            "screenshotsWritten": false, "receiverStarted": false, "privateFFILoaded": true,
            "nativeWarmupBitmapCount": 1, "measuredBitmapCount": 0
        ]
        try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outputPath))
        print("PASS: 180 full-PlayerView ticks; isolated native layout/CPU counters recorded; no window ordering, activation, system input or saved images")
    }
}
