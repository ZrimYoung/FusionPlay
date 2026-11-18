import AppKit
import SwiftUI

@main struct LyricsReflowSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do {
                try await runChecks()
                print("PASS: retained lyric scroll, coalesced viewport follow, wrap transitions, browsing, VoiceOver and reduced motion")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Lyrics reflow check failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor private static func runChecks() async throws {
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "Lyric integration assertion failed") {
            guard condition() else { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        UserDefaults.standard.setVolatileDomain(["appLanguage": "en", "uiFontFamily": "", "uiFontWeight": 400,
            "staggerLyricMotion": true, "lyricStaggerMilliseconds": 1000,
            "lyricLineMoveMilliseconds": 1500, "lyricsFontScalePercent": 200],
                                               forName: UserDefaults.argumentDomain)
        let words = "A quiet morning brings another changing light across the mountains and the sea"
        let bilingual = words + " \u{6e05}\u{6668}\u{7684}\u{5149}\u{9010}\u{6e10}\u{6d12}\u{5411}\u{8fdc}\u{65b9} \u{1f3b5} \u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}"
        let font = AppTypography().nsFont(size: 34, weight: .bold)
        let broad = LyricsReflowText.measure(text: bilingual, font: font, lineSpacing: 3, width: 620)
        let narrow = LyricsReflowText.measure(text: bilingual, font: font, lineSpacing: 3, width: 230)
        precondition(narrow.lineEnds.count > broad.lineEnds.count && narrow.height > broad.height)
        precondition(broad.lineEnds == LyricsReflowText.measure(text: bilingual, font: font, lineSpacing: 3, width: 620).lineEnds)
        for value in [bilingual, "First line\nSecond line\n", "office affine ffi", "\u{0645}\u{0648}\u{0633}\u{064a}\u{0642}\u{0649} \u{05e9}\u{05dc}\u{05d5}\u{05dd}"] {
            for width in [1.0, 170.0, 320.0, 620.0] {
                let layout = LyricsReflowText.measure(text: value, font: font, lineSpacing: 3, width: width)
                precondition(layout.height.isFinite && layout.height > 0 && layout.width.isFinite)
                precondition(layout.lineEnds.last == value.utf16.count,
                             "Reflow measurement dropped UTF-16 text or trailing newline")
                precondition(zip(layout.lineEnds, layout.lineEnds.dropFirst()).allSatisfy { $0 <= $1 })
            }
        }
        var source = ""
        for index in 0..<30 {
            let time = index * 5
            source += String(format: "[%02d:%02d]", time / 60, time % 60) + "\(words) \(index)\n"
            source += String(format: "[%02d:%02d]", time / 60, time % 60) + "\u{6e05}\u{6668}\u{7684}\u{5149}\u{9010}\u{6e10}\u{6d12}\u{5411}\u{8fdc}\u{65b9}\u{ff0c}\u{98ce}\u{5439}\u{8fc7}\u{5c71}\u{5ddd}\u{548c}\u{6d77}\u{6d0b} \(index)\n"
        }
        let document = LyricsDocument(source)
        var follows: [(reason: String, id: Int, animated: Bool)] = []
        var transitions: [(String, Int)] = []
        var waves: [LyricsFollowWave] = []
        var waveClears = 0
        var inputDelays: [Double] = []
        LyricsViewCheckEvents.wave = { if let wave = $0 { waves.append(wave) } else { waveClears += 1 } }
        LyricsReflowTextCheckEvents.inputDelay = { _, delay in inputDelays.append(delay) }
        LyricsViewCheckEvents.follow = { follows.append(($0, $1, $2)) }
        LyricsReflowTextCheckEvents.transition = { transitions.append(($0, $1)) }
        defer { LyricsViewCheckEvents.follow = nil; LyricsReflowTextCheckEvents.transition = nil
            LyricsViewCheckEvents.wave = nil; LyricsReflowTextCheckEvents.inputDelay = nil }
        var samples: [[String: Any]] = []
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        for profile in ["animated", "reduced-motion", "voice-over"] {
            let reduced = profile == "reduced-motion"
            let voiceOver = profile == "voice-over"
            func fixture(_ position: UInt64) -> some View {
                LyricsView(document: document, positionMs: position,
                    loading: false, connected: true, compact: false, canSeek: true, seek: { _ in },
                    checkReduceMotion: reduced, checkVoiceOver: voiceOver)
                    .appTypography().environment(\.colorScheme, .dark)
            }
            inputDelays.removeAll(); waves.removeAll(); waveClears = 0
            let host = NSHostingView(rootView: fixture(52_000))
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 520, height: 580),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.alphaValue = 0; window.orderBack(nil)
            await pause(LyricsReflowText.transitionDuration + LyricsStaggerTiming.maximumSpan + 0.3)
            host.layoutSubtreeIfNeeded()
            let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
            precondition(scrolls.count == 1, "Expected one lyric viewport")
            let scrollIdentity = ObjectIdentifier(scrolls[0])
            precondition(!inputDelays.isEmpty && inputDelays.allSatisfy { $0 >= 0 && $0 <= LyricsStaggerTiming.maximumSpan })
            if reduced || voiceOver { precondition(inputDelays.allSatisfy { $0 == 0 }) }
            else {
                precondition((inputDelays.max() ?? 0) > 0.85 && Set(inputDelays).count > 2,
                             "Visible rows did not pass distinct configured delays to text reflow")
            }
            host.rootView = fixture(56_000); await pause(0.12)
            precondition(waves.count == (reduced || voiceOver ? 0 : 1), "Playback did not honor the stagger/accessibility preference")
            if let wave = waves.last { precondition(wave.span == 1 && wave.duration == 1.5 && wave.direction == 1) }
            host.rootView = fixture(52_000); await pause(0.12)
            if !reduced && !voiceOver { precondition(waves.count == 2 && waves.last?.direction == -1) }
            if !reduced && !voiceOver { await pause(2.6) }
            if !reduced && !voiceOver { precondition(waveClears > 0, "Finished wave kept running") }
            follows.removeAll(); transitions.removeAll()
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            await pause(0.04)
            let widths: [CGFloat] = [500, 480, 460, 420, 400, 360, 330, 300, 340, 380, 430, 480, 520]
            for width in widths {
                window.setContentSize(NSSize(width: width, height: 580))
                await pause(0.04)
                host.layoutSubtreeIfNeeded()
                let current = descendants(host).compactMap { $0 as? NSScrollView }
                precondition(current.count == 1 && ObjectIdentifier(current[0]) == scrollIdentity,
                             "Width reflow recreated lyric viewport")
                precondition(follows.isEmpty, "Live resizing issued per-tick scrollTo")
                precondition(transitions.allSatisfy { $0.1 <= 1 }, "Text retained multiple active reflow plans")
                samples.append(["profile": profile, "width": width, "scrollOrigin": NSStringFromPoint(current[0].contentView.bounds.origin),
                                "followCountDuringResize": follows.count, "scrollRetained": true])
            }
            // A held live resize must not recenter even after the quiet delay.
            await pause(0.3)
            precondition(follows.isEmpty)
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            await pause(LyricsReflowText.transitionDuration + LyricsStaggerTiming.maximumSpan + 0.3)
            let viewportFollows = follows.filter { $0.reason == "viewport" }
            // The native reading anchor can finish without scrolling again.
            // If the selected line changed, only one latest-line follow is allowed.
            precondition(viewportFollows.count <= (voiceOver ? 0 : 1),
                         "Resize issued duplicate final follows")
            if let last = viewportFollows.last { precondition(last.animated == !reduced) }
            if reduced { precondition(!transitions.contains { $0.0 == "begin" }, "Reduced motion still animated text") }
            if profile == "animated" {
                precondition(transitions.contains { $0.0 == "begin" }, "Wrapping never produced a transition")
                window.setContentSize(NSSize(width: 400, height: 580)); await pause(LyricsReflowText.transitionDuration + LyricsStaggerTiming.maximumSpan + 0.3)
            }

            if !voiceOver {
                // Drive the same activity callback as the native scroll monitor.
                let driver = descendants(host).compactMap { $0 as? LyricsActivityCheckDriving }.first
                precondition(driver != nil)
                driver?.beginBrowsingForCheck()
                follows.removeAll()
                window.setContentSize(NSSize(width: 350, height: 580)); await pause(LyricsReflowText.transitionDuration + LyricsStaggerTiming.maximumSpan + 0.3)
                precondition(follows.isEmpty, "Resize interrupted manual lyric browsing")
            }
            window.contentView = nil; window.close(); await pause(0.1)
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "samples": samples,
            "receiverStarted": false, "realPreferencesChanged": false,
            "testedStaggerMilliseconds": 1000, "testedMoveMilliseconds": 1500, "testedFontScalePercent": 200], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("lyrics-reflow-check.json"), options: .atomic)
    }

}
