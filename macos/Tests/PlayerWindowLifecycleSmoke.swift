import AppKit
import Darwin
import SwiftUI

/// Real Window-scene regression: unlike the bitmap layout suite, metadata
/// changes here negotiate AppKit/SwiftUI window minimums and aspect policies.
@main struct PlayerWindowLifecycleSmoke: App {
    @NSApplicationDelegateAdaptor(PlayerLifecycleDelegate.self) private var delegate
    @StateObject private var model: ReceiverModel
    private let root: URL

    init() {
        precondition(Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.player-lifecycle-check")
        let rootURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FUSIONPLAY_LIFECYCLE_ROOT"]!, isDirectory: true)
        root = rootURL
        UserDefaults.standard.setVolatileDomain([
            "appLanguage": "en", "uiFontFamily": "", "uiFontWeight": 400,
            "playerLyricsDisplayMode": "always", "playerShowsProgress": true, "playerShowsTransport": true,
            "playerControlsAlwaysVisible": true, "playerWindowPinned": false, "playerShowsPinButton": false,
            "ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false
        ], forName: UserDefaults.argumentDomain)
        _model = StateObject(wrappedValue: ReceiverModel.preview(Self.track("initial", lyrics: true), artwork: nil, root: rootURL))
    }
    static func track(_ id: String, lyrics: Bool) -> Snapshot {
        Snapshot(phase: .playing, title: "Synthetic " + id, artist: "Lifecycle Check", album: "Preview",
            trackId: id, artworkUrl: "", lyricsText: lyrics ? "[00:00]Opening line\n[00:06]A new morning\n[00:12]Another line\n[00:18]" : "",
            durationMs: 180_000, positionMs: 8_000, controlsAvailable: true, volume: 50,
            message: "", address: "", output: "", queueMs: 0, outputLatencyMs: 0, scheduleErrorMs: 0,
            underruns: 0, droppedFrames: 0, resyncs: 0,
            displayTitle: nil, displayArtist: nil, displayAlbum: nil)
    }
    static func stressTrack(_ cycle: Int, lyrics: Bool) -> Snapshot {
        var state = track("stress-\(cycle)", lyrics: false)
        state.title = ["Synthetic dawn", "A deliberately longer synthetic track title for layout stress", "合成曲目 · 窗口压力检查"][cycle % 3]
        state.album = "Synthetic collection \(cycle % 7)"
        state.durationMs = 360_000
        if lyrics {
            let count = [2, 8, 24, 64, 128][cycle % 5]
            state.lyricsText = (0..<count).map { line in
                let second = line * 2
                let suffix = line.isMultiple(of: 3) ? " with a longer synthetic sentence to exercise line wrapping" : ""
                return String(format: "[%02d:%02d]", second / 60, second % 60) + "Synthetic line \(line + 1), cycle \(cycle)" + suffix
            }.joined(separator: "\n")
        }
        return state
    }
    static func syntheticArtwork(_ cycle: Int) -> NSImage {
        let hue = CGFloat(cycle % 17) / 17
        let start = NSColor(calibratedHue: hue, saturation: 0.65, brightness: 0.85, alpha: 1)
        let end = NSColor(calibratedHue: (hue + 0.35).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.35, alpha: 1)
        return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSGradient(starting: start, ending: end)?.draw(in: rect, angle: CGFloat(cycle % 4) * 45)
            return true
        }
    }
    var body: some Scene {
        Window("FusionPlay Player Lifecycle Check", id: "player-lifecycle") {
            PlayerView(model: model).appTypography()
                .environment(\.locale, Locale(identifier: "en"))
                .background(PlayerLifecycleProbe(model: model, root: root).frame(width: 0, height: 0))
        }.defaultSize(width: 760, height: 400)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
    }
}

final class PlayerLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The public AppKit property can be inspected across the generic hosting-view
/// subclasses installed by a Window scene, without private KVC or class names.
private protocol LifecycleHostingSizingOptions {
    var sizingOptions: NSHostingSizingOptions { get set }
}
extension NSHostingView: LifecycleHostingSizingOptions {}

private struct PlayerLifecycleProbe: NSViewRepresentable {
    let model: ReceiverModel
    let root: URL
    func makeNSView(context: Context) -> DriverView { DriverView(model: model, root: root) }
    func updateNSView(_ view: DriverView, context: Context) {}

    final class DriverView: NSView {
        private let model: ReceiverModel
        private let root: URL
        private var started = false
        private var observations: [[String: Any]] = []
        private var violations: [String] = []
        private var expectedSize: NSSize?
        private var activeMode = "always"
        private var activeProfile = "initial"
        private var stressSeconds: Double = 0
        private var stressCycles = 0
        private var stressElapsed: Double = 0
        init(model: ReceiverModel, root: URL) {
            self.model = model; self.root = root
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !started else { return }
            started = true; window.alphaValue = 1; window.orderBack(nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                await run(window)
            }
        }
        private func persist(_ complete: Bool = false) {
            let record: [String: Any] = ["complete": complete, "passed": complete && violations.isEmpty,
                "violations": violations, "observations": observations,
                "stressSecondsRequested": stressSeconds, "stressCycles": stressCycles, "stressElapsedSeconds": stressElapsed]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: root.appendingPathComponent("result.json"), options: .atomic)
            }
        }
        private func hostingViews(_ window: NSWindow) -> [[String: Any]] {
            guard let rootView = window.contentView else { return [] }
            var queue: [(NSView, String)] = [(rootView, "content")]
            var parent = rootView.superview
            while let view = parent {
                queue.append((view, "ancestor")); parent = view.superview
            }
            var visited = Set<ObjectIdentifier>()
            var hosts: [[String: Any]] = []
            var index = 0
            while index < queue.count {
                let (view, relation) = queue[index]; index += 1
                guard visited.insert(ObjectIdentifier(view)).inserted else { continue }
                if let host = view as? LifecycleHostingSizingOptions {
                    hosts.append(["class": String(NSStringFromClass(type(of: view)).prefix(240)),
                        "relation": relation, "sizingOptions": host.sizingOptions.rawValue,
                        "bounds": NSStringFromRect(view.bounds),
                        "windowFrame": NSStringFromRect(view.convert(view.bounds, to: nil))])
                }
                // Ancestors are inspected themselves; descending from them would
                // enumerate unrelated titlebar and native window chrome.
                if relation != "ancestor" {
                    queue.append(contentsOf: view.subviews.map { ($0, "descendant") })
                }
            }
            return hosts
        }
        private func record(_ stage: String, window: NSWindow, checkSize: Bool = true) {
            let content = window.contentRect(forFrameRect: window.frame).size
            var entry: [String: Any] = ["stage": stage, "mode": activeMode, "profile": activeProfile,
                "time": ProcessInfo.processInfo.systemUptime, "windowFrame": NSStringFromRect(window.frame),
                "contentSize": NSStringFromSize(content), "contentLayoutRect": NSStringFromRect(window.contentLayoutRect),
                "contentMinSize": NSStringFromSize(window.contentMinSize), "contentMaxSize": NSStringFromSize(window.contentMaxSize),
                "aspectRatio": NSStringFromSize(window.aspectRatio), "contentAspectRatio": NSStringFromSize(window.contentAspectRatio),
                "resizeIncrements": NSStringFromSize(window.resizeIncrements), "styleMask": window.styleMask.rawValue,
                "inLiveResize": window.inLiveResize, "lyricsAvailable": model.lyricsAvailable,
                "lyricsLoading": model.lyricsLoading, "lyricLineCount": model.lyrics.lines.count,
                "trackId": model.snapshot?.trackId ?? "",
                "contentViewClass": window.contentView.map { String(NSStringFromClass(type(of: $0)).prefix(240)) } ?? "none",
                "hostingViews": hostingViews(window), "stressCycle": stressCycles,
                "artworkSize": model.artwork.map { NSStringFromSize($0.size) } ?? "none"]
            if let expectedSize {
                let preserved = abs(content.width - expectedSize.width) <= 2 && abs(content.height - expectedSize.height) <= 2
                entry["expectedContentSize"] = NSStringFromSize(expectedSize); entry["customFramePreserved"] = preserved
                if checkSize && !preserved { violations.append("\(activeMode)/\(activeProfile)/\(stage): custom frame \(NSStringFromSize(expectedSize)) changed to \(NSStringFromSize(content))") }
            }
            observations.append(entry); persist()
            FileHandle.standardError.write(Data("\(activeMode)/\(activeProfile)/\(stage): content=\(NSStringFromSize(content)) min=\(NSStringFromSize(window.contentMinSize)) lyrics=\(model.lyricsAvailable)\n".utf8))
        }
        private func preference(_ mode: String) {
            let defaults = UserDefaults.standard
            var values = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            values["playerLyricsDisplayMode"] = mode
            defaults.willChangeValue(forKey: "playerLyricsDisplayMode")
            defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
            defaults.didChangeValue(forKey: "playerLyricsDisplayMode")
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        private func pause(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        private func parserSettled(window: NSWindow) async -> Bool {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while model.lyricsLoading && ProcessInfo.processInfo.systemUptime < deadline { await pause(0.01) }
            if model.lyricsLoading { violations.append("Lyrics parser did not settle"); record("parser-timeout", window: window); return false }
            return true
        }
        @MainActor private func run(_ window: NSWindow) async {
            let requested = ProcessInfo.processInfo.environment["FUSIONPLAY_LIFECYCLE_MODE"] ?? "all"
            let modes = requested == "all" ? ["always", "automatic"] : [requested]
            guard modes.allSatisfy({ ["always", "automatic"].contains($0) }) else { exit(2) }
            record("scene-start", window: window, checkSize: false)
            for mode in modes {
                activeMode = mode
                preference(mode)
                for size in [NSSize(width: 420, height: 800), NSSize(width: 500, height: 900), NSSize(width: 892, height: 650)] {
                    activeProfile = "\(size.width < 600 ? "mini" : "wide")-\(Int(size.width))x\(Int(size.height))"
                    expectedSize = nil
                    model.previewLyricsUpdate(PlayerWindowLifecycleSmoke.track("\(mode)-\(activeProfile)-A", lyrics: true))
                    guard await parserSettled(window: window) else { finish(window); return }
                    await pause(0.35)
                    record("before-manual-size", window: window, checkSize: false)
                    window.setContentSize(size)
                    await pause(0.55)
                    expectedSize = size
                    record("custom-size-ready", window: window)
                    for cycle in 1...3 {
                        let next = "\(mode)-\(activeProfile)-\(cycle)"
                        record("\(cycle)-before-empty", window: window)
                        model.previewLyricsUpdate(PlayerWindowLifecycleSmoke.track(next, lyrics: false))
                        record("\(cycle)-empty-first-frame", window: window)
                        await pause(0.12)
                        record("\(cycle)-empty-visible", window: window)
                        model.previewLyricsUpdate(PlayerWindowLifecycleSmoke.track(next, lyrics: true))
                        record("\(cycle)-late-lyrics-queued", window: window)
                        guard await parserSettled(window: window) else { finish(window); return }
                        await pause(0.40)
                        record("\(cycle)-late-lyrics-settled", window: window)
                    }
                    // Programmatic resize bursts exercise the same native
                    // negotiation without claiming to synthesize a mouse drag.
                    for offset in [10.0, -10.0, 20.0, 0.0] {
                        record("resize-stream-before-\(offset)", window: window, checkSize: false)
                        window.setContentSize(NSSize(width: size.width + offset, height: size.height + offset))
                        await pause(0.025)
                        record("resize-stream-after-\(offset)", window: window, checkSize: false)
                    }
                    await pause(0.4)
                    record("resize-stream-settled", window: window)
                }
            }
            let stressRequest = ProcessInfo.processInfo.environment["FUSIONPLAY_LIFECYCLE_STRESS_SECONDS"] ?? "0"
            guard let requestedSeconds = Double(stressRequest), requestedSeconds.isFinite, requestedSeconds >= 0 else {
                violations.append("Invalid stress duration: expected a finite nonnegative number")
                finish(window); return
            }
            if requestedSeconds > 0 { await stress(window, seconds: requestedSeconds) }
            finish(window)
        }
        @MainActor private func stress(_ window: NSWindow, seconds: Double) async {
            stressSeconds = seconds
            activeMode = "automatic"; preference(activeMode)
            let began = ProcessInfo.processInfo.systemUptime
            record("stress-begin", window: window, checkSize: false)
            while ProcessInfo.processInfo.systemUptime - began < seconds {
                let cycleBegan = ProcessInfo.processInfo.systemUptime
                stressCycles += 1
                let size = ((stressCycles - 1) / 5).isMultiple(of: 2)
                    ? NSSize(width: 500, height: 900) : NSSize(width: 892, height: 650)
                activeProfile = "stress-\(size.width < 600 ? "mini" : "wide")-\(Int(size.width))x\(Int(size.height))"
                if expectedSize != size {
                    expectedSize = nil
                    window.setContentSize(size)
                    await pause(0.12)
                    expectedSize = size
                    record("stress-profile-ready", window: window)
                }
                record("stress-before-empty", window: window)
                model.previewLyricsUpdate(PlayerWindowLifecycleSmoke.stressTrack(stressCycles, lyrics: false))
                // Only synthetic artwork is used. The transaction mirrors the
                // production cover replacement without network or disk images.
                withAnimation(.easeInOut(duration: 0.35)) {
                    model.artwork = PlayerWindowLifecycleSmoke.syntheticArtwork(stressCycles)
                }
                record("stress-empty-first-frame", window: window)
                await pause(0.12)
                record("stress-empty-visible", window: window)
                model.previewLyricsUpdate(PlayerWindowLifecycleSmoke.stressTrack(stressCycles, lyrics: true))
                record("stress-late-lyrics-queued", window: window)
                guard await parserSettled(window: window) else { return }
                await pause(0.40)
                stressElapsed = ProcessInfo.processInfo.systemUptime - began
                record("stress-late-lyrics-settled", window: window)
                // About one track per second. Every wait yields to AppKit and
                // remains short; the parent process enforces a hard deadline.
                let remainder = 1 - (ProcessInfo.processInfo.systemUptime - cycleBegan)
                if remainder > 0 { await pause(min(1, remainder)) }
            }
            stressElapsed = ProcessInfo.processInfo.systemUptime - began
            record("stress-complete", window: window)
        }
        private func finish(_ window: NSWindow) {
            persist(true)
            let message = (violations.isEmpty ? "PASS" : "FAIL") + ": player metadata/window lifecycle; \(violations.count) frame violations\n"
            FileHandle.standardError.write(Data(message.utf8))
            window.orderOut(nil); exit(violations.isEmpty ? 0 : 1)
        }
    }
}
