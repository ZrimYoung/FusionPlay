import AppKit
import Darwin
import SwiftUI

/// No receiver, FFI library, system media session or visible test window.
@main struct LyricsResizePerformance {
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
    private static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    @MainActor private static func pause(_ seconds: Double) async {
        if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
    }
    @MainActor private static func run() async throws {
        let mode = CommandLine.arguments[1]
        let scenario = CommandLine.arguments[2]
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        UserDefaults.standard.setVolatileDomain([
            "appLanguage": "en", "uiFontFamily": "", "uiFontWeight": 400,
            "staggerLyricMotion": true, "lyricStaggerMilliseconds": 140,
            "lyricLineMoveMilliseconds": 420, "lyricsFontScalePercent": 100
        ], forName: UserDefaults.argumentDomain)
        let host = NSHostingView(rootView: PerformanceLyricsFixture(mode: mode, scenario: scenario))
        let window = PerformancePanel(contentRect: NSRect(x: 50, y: 50, width: 680, height: 720),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        await pause(0.8)
        host.layoutSubtreeIfNeeded()
        var clipEvents = 0
        let clips = descendants(host).compactMap { $0 as? NSScrollView }.map(\.contentView)
        let observers = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { _ in
                clipEvents += 1
            }
        }
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        NativeLyricsReflowBenchmark.reset()
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        await pause(0.04)
        let count = scenario == "unchanged" ? 100 : 160
        var work: [Double] = [], lateness: [Double] = []
        let startCPU = cpu()
        let started = ProcessInfo.processInfo.systemUptime
        for tick in 0..<count {
            let planned = started + Double(tick) / 60
            await pause(planned - ProcessInfo.processInfo.systemUptime)
            let begin = ProcessInfo.processInfo.systemUptime
            lateness.append(max(0, begin - planned))
            let phase = Double(tick) / Double(count - 1)
            let triangular = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            let width: Double
            if mode == "compact" { width = scenario == "unchanged" ? 400 + triangular * 70 : 400 - triangular * 140 }
            else { width = scenario == "unchanged" ? 600 + triangular * 70 : 660 - triangular * 330 }
            window.setContentSize(NSSize(width: width, height: 720))
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            work.append(ProcessInfo.processInfo.systemUptime - begin)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let resizingCPU = cpu() - startCPU
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        await pause(0.9)
        func quantile(_ values: [Double], _ fraction: Double) -> Double {
            let values = values.sorted()
            return values[min(values.count - 1, Int(Double(values.count - 1) * fraction))] * 1_000
        }
        let result: [String: Any] = [
            "mode": mode, "scenario": scenario, "ticks": count,
            "resizeCPUSeconds": resizingCPU, "resizeWallSeconds": elapsed,
            "workP50ms": quantile(work, 0.5), "workP95ms": quantile(work, 0.95), "workMaxms": (work.max() ?? 0) * 1_000,
            "lateP95ms": quantile(lateness, 0.95), "workOver16ms": work.filter { $0 > 1.0 / 60 }.count,
            "nativeClipBoundsChanges": clipEvents, "counters": NativeLyricsReflowBenchmark.snapshot(),
            "visibleWindows": false, "receiverStarted": false, "FFILoaded": false,
            "measurement": "CPU and main-thread resize/layout work; not display-compositor FPS"
        ]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("\(mode)/\(scenario): CPU=\(String(format: "%.3f", resizingCPU))s p95=\(String(format: "%.2f", quantile(work, 0.95)))ms over16ms=\(work.filter { $0 > 1.0 / 60 }.count)/\(count) clips=\(clipEvents) counters=\(NativeLyricsReflowBenchmark.snapshot())")
        precondition(window.alphaValue == 0)
    }
}

private final class PerformancePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct PerformanceLyricsFixture: View {
    let mode: String
    let scenario: String
    private var original: String {
        scenario == "unchanged" ? "A quiet morning" : "A quiet morning brings another changing light across the mountains and the sea"
    }
    private var translation: String {
        scenario == "unchanged" ? "清晨的光" : "清晨的光逐渐洒向远方，风吹过山川和海洋，新的故事正在发生"
    }
    private var document: LyricsDocument {
        LyricsDocument((0..<12).map { index in
            let time = String(format: "[%02d:%02d]", index * 6 / 60, index * 6 % 60)
            return time + original + " \(index)\n" + time + translation + " \(index)"
        }.joined(separator: "\n"))
    }
    var body: some View {
        Group {
            if mode == "native" {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(0..<12) { index in
                                VStack(alignment: .leading, spacing: 7) {
                                    LyricsReflowText(text: original + " \(index)", font: .systemFont(ofSize: 34, weight: .bold),
                                        lineSpacing: 3, reduceMotion: false, width: max(1, geometry.size.width - 48), motionDelay: Double(index) / 11 * 0.14)
                                    LyricsReflowText(text: translation + " \(index)", font: .systemFont(ofSize: 20, weight: .semibold),
                                        lineSpacing: 0, reduceMotion: false, width: max(1, geometry.size.width - 48), motionDelay: Double(index) / 11 * 0.14)
                                }
                            }
                        }.padding(24)
                    }
                }
            } else {
                LyricsView(document: document, positionMs: 36_000, loading: false, connected: true,
                           compact: mode == "compact", canSeek: false, seek: { _ in }).appTypography()
            }
        }.foregroundStyle(.white).environment(\.colorScheme, .dark)
    }
}
