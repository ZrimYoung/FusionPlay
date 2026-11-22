import AppKit
import SwiftUI

/// Real production PlayerView, window and native controls. No receiver, window
/// ordering, global input, event posting, screen capture or activation is used.
@main struct PlayerTransportIntegrationSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        do { try check(); exit(0) }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func check() throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "PlayerTransportIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        func pump(_ root: NSView) {
            let until = Date().addingTimeInterval(0.18)
            repeat {
                root.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            } while Date() < until
        }
        func commandName(_ command: PlaybackCommand) -> String {
            switch command { case .previous: "previous"; case .pause: "pause"; case .play: "play"; case .next: "next" }
        }
        let initial = Snapshot(phase: .playing, title: "Silent transport input", artist: "Synthetic", album: "Check",
            trackId: "input-check", artworkUrl: "", lyricsText: "[00:00]First line\n[00:10]Current line\n[00:30]Next line",
            durationMs: 180_000, positionMs: 10_000, controlsAvailable: true, volume: 50, message: "", address: "",
            output: "", queueMs: 0, outputLatencyMs: 0, scheduleErrorMs: 0, underruns: 0, droppedFrames: 0, resyncs: 0)
        let cases: [(String, CGSize, NarrowPlayerLayout, Bool)] = [
            ("wide-lyrics", CGSize(width: 1000, height: 700), .ipadPaged, true),
            ("wide-glass", CGSize(width: 1000, height: 700), .ipadPaged, false),
            ("narrow-cover", CGSize(width: 420, height: 420), .squarePaged, true),
            ("narrow-album", CGSize(width: 420, height: 760), .ipadPaged, true)
        ]
        var nativeHits = 0, mappedActions = 0, hiddenChecks = 0
        for (name, size, layout, showsLyrics) in cases {
            UserDefaults.standard.setVolatileDomain([
                "appLanguage": "en", "playerControlsAlwaysVisible": true, "playerWindowPinned": false,
                "playerShowsPinButton": false, "playerShowsTransport": true, "playerShowsProgress": true,
                "coverPlayerShowsTransport": true, "coverPlayerShowsProgress": true,
                "albumPlayerShowsTransport": true, "albumPlayerShowsProgress": true,
                "playerLyricsDisplayMode": showsLyrics ? "automatic" : "never", "coverLyricsExpandedByDragging": false,
                "narrowPlayerLayout": layout.rawValue, "wrapPlayerMetadata": false, "uiCorrectLyricTitles": false,
                "lyricsPageShowsArtwork": true, "lyricsPageShowsTrackInfo": true
            ], forName: UserDefaults.argumentDomain)
            let model = ReceiverModel.preview(initial, artwork: nil,
                root: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
            var commands: [String] = []
            model.previewControlCommand = { commands.append(commandName($0)) }
            let driver = PlayerResponsiveMotionDriver(animationsEnabled: false, automaticallyTicks: false)
            let host = NSHostingView(rootView: AnyView(PlayerView(model: model, responsiveMotion: driver).appTypography()))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.alphaValue = 0; host.frame = CGRect(origin: .zero, size: size); window.contentView = host
            defer { window.contentView = nil; window.close(); driver.stop(); model.previewControlCommand = nil }
            pump(host)
            let buttons = descendants(host).compactMap { $0 as? PlayerTransportButton.TransportButton }
            try require(buttons.count == 3, "\(name): expected exactly three production transport controls, got \(buttons.count)")
            func button(_ role: String) throws -> PlayerTransportButton.TransportButton {
                guard let view = buttons.first(where: { $0.accessibilityIdentifier() == "fusionplay.player.transport." + role }) else {
                    throw NSError(domain: "\(name): missing transport \(role)", code: 1)
                }
                return view
            }
            func rootHit(_ view: NSView) -> NSView? {
                let point = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: host.superview)
                return host.hitTest(point)
            }
            for role in ["previous", "playPause", "next"] {
                let view = try button(role)
                let hit = rootHit(view)
                try require(view.focusRingType == .none, "Transport focus ring should remain hidden")
                try require(view.isEnabled && view.interactive && !view.isHiddenOrHasHiddenAncestor,
                            "\(name): \(role) is not enabled and interactive")
                try require(hit === view || hit?.isDescendant(of: view) == true,
                            "\(name): hosting-root hit for \(role) was stolen by \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
                nativeHits += 1
                view.performClick(nil)
            }
            try require(commands == ["previous", "pause", "next"], "\(name): wrong playing command mapping \(commands)")
            mappedActions += 3
            var paused = initial; paused.phase = .paused; model.snapshot = paused
            pump(host)
            try button("playPause").performClick(nil)
            try require(commands == ["previous", "pause", "next", "play"], "\(name): paused toggle did not dispatch play")
            mappedActions += 1
            if size.width < 600 {
                guard let paging = host.gestureRecognizers.compactMap({ $0.target as? NarrowPlayerHorizontalScroll.Coordinator }).first,
                      paging.enabled else { throw NSError(domain: "\(name): missing actual pager bridge", code: 1) }
                // Invoke only this test's production binding callback. No event
                // reaches an application/window/system input queue.
                paging.requestPage(.lyrics); pump(host)
                for view in buttons {
                    let local = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: view.superview)
                    try require(!view.interactive && view.hitTest(local) == nil,
                                "\(name): hidden playback control consumed lyric-page input")
                    view.performClick(nil)
                    hiddenChecks += 1
                }
                try require(commands.count == 4, "\(name): hidden transport dispatched commands from the lyric page")
                paging.requestPage(.playback); pump(host)
                let restored = try button("playPause")
                let hit = rootHit(restored)
                try require(restored.interactive && (hit === restored || hit?.isDescendant(of: restored) == true),
                            "\(name): playback-page transport failed to recover native hit ownership")
                restored.performClick(nil)
                try require(commands.last == "play" && commands.count == 5, "\(name): restored transport lost its callback")
                nativeHits += 1; mappedActions += 1
            }
            try require(!window.isVisible && window.alphaValue == 0 && NSApp.activationPolicy() == .prohibited
                        && !NSRunningApplication.current.isActive, "\(name): test showed or activated a window")
            print("PASS: \(name) real PlayerView native input and command mapping")
        }
        print("PASS: \(nativeHits) hosting-root production hits, \(mappedActions) real mapped model commands, \(hiddenChecks) lyric-page passthrough checks; no live receiver/system input/window ordering/activation/capture")
    }
}
