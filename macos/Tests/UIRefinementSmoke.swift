import AppKit
import SwiftUI

@main struct UIRefinementSmoke {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let stateRoot = output.appendingPathComponent("isolated-state")
        let receiver = try Receiver(dataDirectory: stateRoot.appendingPathComponent("data").path)
        defer { receiver.stop() }
        var state = receiver.snapshot()
        state.controlsAvailable = true; state.phase = .playing
        state.trackId = "preview-track"; state.title = "Never Let a Good Thing Die"
        state.artist = "Carly Rae Jepsen"; state.album = "The Loveliest Time"
        state.durationMs = 240_000; state.positionMs = 78_000
        let artwork = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let gradient = NSGradient(colors: [NSColor.systemOrange, NSColor.systemPink, NSColor.systemIndigo])!
            gradient.draw(in: rect, angle: 45)
            NSColor.white.withAlphaComponent(0.15).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 70, dy: 70)).fill()
            NSColor.white.withAlphaComponent(0.5).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 168, dy: 168)).fill()
            return true
        }
        func preferences(_ language: String, _ extras: [String: Any] = [:]) {
            var values: [String: Any] = ["appLanguage": language, "playerControlsAlwaysVisible": true,
                "playerShowsTransport": true, "playerShowsProgress": true, "playerLyricsDisplayMode": "automatic", "playerProgressColorMode": "white",
                "showDockIcon": true, "showMenuBarIcon": true, "playerWindowPinned": false, "playerShowsPinButton": false,
                "settingsSidebarVisible": true, "uiFontFamily": "", "uiFontWeight": 400, "uiCorrectLyricTitles": false]
            values.merge(extras) { _, new in new }
            UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        }
        var renderedCases = 0
        @MainActor func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
            let host = NSHostingView(rootView: view.appTypography().environment(\.colorScheme, .dark)
                .environment(\.locale, Locale(identifier: UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans")))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.alphaValue = 0; window.orderBack(nil)
            window.setContentSize(NSSize(width: width, height: height))
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            if name.hasPrefix("lyrics-") || name.hasPrefix("stopped-") || width >= 600 && name.hasPrefix("player-") {
                precondition(window.styleMask.contains(.resizable), "Player lost native resizing: " + name)
                precondition(window.aspectRatio == .zero && window.contentAspectRatio == .zero,
                             "Player retained an aspect lock: " + name)
                let titlebarInset = max(host.safeAreaInsets.top, window.frame.height - window.contentLayoutRect.height)
                let expectedMinimum: CGFloat = 260
                FileHandle.standardError.write(Data("native minimum \(name): \(window.contentMinSize), titlebar \(titlebarInset)\n".utf8))
                precondition(window.contentMinSize.width <= 260 && window.contentMinSize.height <= expectedMinimum + titlebarInset,
                             "Player minimum grew with content: " + name)
                precondition(window.contentMinSize.height >= expectedMinimum,
                             "Player lost its fixed native minimum: " + name)
            }
            func rows(in view: NSView) -> Int {
                let own = (view as? NSTableView)?.numberOfRows ?? 0
                return own + view.subviews.reduce(0) { $0 + rows(in: $1) }
            }
            if name.hasPrefix("settings-") {
                let rowCount = rows(in: host)
                FileHandle.standardError.write(Data("native sidebar rows: \(rowCount)\n".utf8))
                precondition(rowCount >= ReceiverSettingsPage.allCases.count, "Settings sidebar has missing native rows")
            }
            FileHandle.standardError.write(Data("render \(name): requested \(width)x\(height), actual \(host.bounds)\n".utf8))
            precondition(host.bounds.width <= width + 1 && host.bounds.height <= window.frame.height + 1, "Root exceeded native window bounds: \(name)")
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No render surface") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No image") }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            if name != "warmup" { renderedCases += 1 }
            window.contentView = nil; window.close()
        }
        // Warm up AppKit's offscreen rendering before capturing the actual cases.
        try render(Text("FusionPlay").padding(), width: 240, height: 80, name: "warmup")
        var count = 0
        for language in ["zh-Hans", "en"] {
            preferences(language)
            let model = ReceiverModel.preview(state, artwork: artwork, root: stateRoot)
            for size in [NSSize(width: 660, height: 500), NSSize(width: 820, height: 620)] {
                for page in ReceiverSettingsPage.allCases {
                    try render(SettingsPanel(model: model, initialPage: page), width: size.width, height: size.height,
                               name: "settings-\(language)-\(page.rawValue)-\(Int(size.width))")
                    count += 1
                }
            }
        }
        preferences("zh-Hans")
        let model = ReceiverModel.preview(state, artwork: artwork, root: stateRoot)
        for size in [NSSize(width: 260, height: 260), NSSize(width: 420, height: 420), NSSize(width: 760, height: 400), NSSize(width: 600, height: 360), NSSize(width: 892, height: 650)] {
            try render(PlayerView(model: model), width: size.width, height: size.height, name: "player-\(Int(size.width))")
            count += 1
        }
        preferences("zh-Hans", ["playerShowsProgress": false, "playerShowsTransport": false])
        try render(PlayerView(model: model), width: 260, height: 260, name: "player-hidden-sections")
        preferences("en", ["playerProgressColorMode": "custom", "playerProgressCustomHex": "#FF9F0A"])
        try render(PlayerView(model: model), width: 420, height: 420, name: "player-custom-color")
        preferences("zh-Hans")
        try render(ReceiverPanel(model: model), width: 280, height: 180, name: "menu-long-title")
        var lyricState = state
        lyricState.title = "A Quiet Morning"; lyricState.artist = "FusionPlay"; lyricState.album = "Preview"
        lyricState.positionMs = 7_000
        lyricState.lyricsText = "[00:00.00]The sky turns blue\n[00:00.00]天空染上蓝色\n[00:06.00]A quiet morning fills the room\n[00:06.00]清晨的宁静漫进房间\n[00:12.00]We follow the light\n[00:18.00]"
        for language in ["zh-Hans", "en"] {
            preferences(language, ["playerLyricsDisplayMode": "always"])
            let lyricModel = ReceiverModel.preview(lyricState, artwork: artwork, root: stateRoot)
            precondition(lyricModel.lyrics.isTimed && lyricModel.lyrics.lines.count == 4)
            for size in [NSSize(width: 260, height: 440), NSSize(width: 420, height: 700), NSSize(width: 760, height: 400), NSSize(width: 840, height: 300), NSSize(width: 1200, height: 800), NSSize(width: 892, height: 650), NSSize(width: 1040, height: 700)] {
                try render(PlayerView(model: lyricModel), width: size.width, height: size.height,
                           name: "lyrics-\(language)-\(Int(size.width))")
                count += 1
            }
        }
        preferences("zh-Hans", ["playerLyricsDisplayMode": "always", "playerControlsAlwaysVisible": false,
                                 "playerShowsProgress": false, "playerShowsTransport": false])
        let lyricModel = ReceiverModel.preview(lyricState, artwork: artwork, root: stateRoot)
        try render(PlayerView(model: lyricModel), width: 260, height: 440, name: "lyrics-cover-only")
        count += 1
        lyricState.lyricsText = ""
        let noLyrics = ReceiverModel.preview(lyricState, artwork: artwork, root: stateRoot)
        try render(PlayerView(model: noLyrics), width: 260, height: 440, name: "lyrics-empty")
        count += 1
        lyricState.lyricsText = "The sky turns blue\nA quiet morning fills the room\nWe follow the light"
        let untimed = ReceiverModel.preview(lyricState, artwork: artwork, root: stateRoot)
        try render(PlayerView(model: untimed), width: 420, height: 700, name: "lyrics-untimed")
        count += 1
        preferences("zh-Hans", ["playerLyricsDisplayMode": "always"])
        try render(PlayerView(model: lyricModel), width: 420, height: 556, name: "lyrics-short-portrait")
        count += 1
        lyricState.controlsAvailable = false; lyricState.phase = .ready
        lyricState.trackId = ""; lyricState.title = ""; lyricState.artist = ""; lyricState.album = ""
        lyricState.lyricsText = ""; lyricState.positionMs = nil; lyricState.durationMs = nil
        let stopped = ReceiverModel.preview(lyricState, artwork: nil, root: stateRoot)
        for size in [NSSize(width: 260, height: 440), NSSize(width: 760, height: 400), NSSize(width: 840, height: 300)] {
            try render(PlayerView(model: stopped), width: size.width, height: size.height,
                       name: "stopped-\(Int(size.width))")
            count += 1
        }
        // Exercise the production model's asynchronous parser and availability,
        // including a new track arriving with lyrics in the same snapshot.
        preferences("en", ["playerLyricsDisplayMode": "automatic"])
        let automatic = ReceiverModel.preview(lyricState, artwork: artwork, root: stateRoot)
        precondition(!automatic.lyricsAvailable)
        var arriving = state
        arriving.trackId = "auto-first"; arriving.lyricsText = "[00:00]A new morning"
        automatic.previewLyricsUpdate(arriving)
        precondition(automatic.lyricsLoading && !automatic.lyricsAvailable)
        func settleLyrics() {
            let deadline = Date().addingTimeInterval(3)
            while automatic.lyricsLoading && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(!automatic.lyricsLoading, "Lyric parsing did not finish")
        }
        settleLyrics(); precondition(automatic.lyricsAvailable)
        arriving.trackId = "auto-second"; arriving.lyricsText = "[00:00]Another morning"
        automatic.previewLyricsUpdate(arriving)
        precondition(automatic.lyricsLoading && automatic.lyricsAvailable,
                     "Track change collapsed automatic lyrics during parsing")
        settleLyrics(); precondition(automatic.lyricsAvailable)
        try render(PlayerView(model: automatic), width: 420, height: 700, name: "lyrics-auto-arrived")
        try render(PlayerView(model: automatic), width: 1200, height: 800, name: "lyrics-auto-wide")
        arriving.trackId = "auto-empty"; arriving.lyricsText = ""
        automatic.previewLyricsUpdate(arriving)
        precondition(automatic.lyricsAvailable && automatic.lyricsLoading,
                     "A new empty first frame must retain the pane during the metadata wait")
        settleLyrics()
        precondition(!automatic.lyricsAvailable && !automatic.lyricsLoading)
        try render(PlayerView(model: automatic), width: 260, height: 260, name: "auto-empty-square")
        try render(PlayerView(model: automatic), width: 760, height: 400, name: "auto-empty-wide")
        arriving.lyricsText = "Lyrics arriving late"
        automatic.previewLyricsUpdate(arriving); settleLyrics()
        precondition(automatic.lyricsAvailable)
        arriving.controlsAvailable = false
        automatic.previewLyricsUpdate(arriving)
        precondition(!automatic.lyricsAvailable && !automatic.lyricsLoading)
        preferences("zh-Hans", ["playerLyricsDisplayMode": "never"])
        try render(PlayerView(model: lyricModel), width: 260, height: 260, name: "never-lyrics-square")
        count += 5
        precondition(count + 3 == 50 && renderedCases == 50, "Original rendering cases were lost")

        // Exercise the production typography modifier, including CJK fallback
        // glyphs in a Latin family and a preserved unavailable-family setting.
        var fixtureState = state
        fixtureState.trackId = "typography-preview"; fixtureState.title = "A Quiet Morning"
        fixtureState.artist = "FusionPlay"; fixtureState.album = "Preview"
        fixtureState.positionMs = 78_000
        fixtureState.lyricsText = "[00:00]The sky turns blue\n[01:00]A quiet morning fills the room\n[01:00]清晨的宁静漫进房间\n[02:00]We follow the light\n[03:00]"
        let availableLyrics = ReceiverModel.preview(fixtureState, artwork: artwork, root: stateRoot)
        var emptyFixture = fixtureState; emptyFixture.lyricsText = ""
        let absentLyrics = ReceiverModel.preview(emptyFixture, artwork: artwork, root: stateRoot)
        let missingFamily = "FusionPlay-UI-Check-Missing-Family-14CB"
        precondition(FontCatalog.installedFamilies.contains { $0.name == "Helvetica Neue" },
                     "The custom-font render must exercise an installed family")
        precondition(AppTypography(family: missingFamily).isMissing)
        for language in ["zh-Hans", "en"] {
            for (label, family, weight) in [("custom", "Helvetica Neue", 600), ("missing", missingFamily, 400)] {
                preferences(language, ["uiFontFamily": family, "uiFontWeight": weight, "playerLyricsDisplayMode": "never"])
                try render(SettingsPanel(model: availableLyrics, initialPage: .appearance), width: 660, height: 500,
                           name: "settings-font-\(label)-\(language)")
                try render(PlayerView(model: availableLyrics), width: 600, height: 360,
                           name: "player-font-\(label)-\(language)")
                try render(ReceiverPanel(model: availableLyrics), width: 280, height: 180,
                           name: "menu-font-\(label)-\(language)")
                preferences(language, ["uiFontFamily": family, "uiFontWeight": weight, "playerLyricsDisplayMode": "always"])
                try render(PlayerView(model: availableLyrics), width: 892, height: 650,
                           name: "lyrics-font-\(label)-\(language)")
            }
            for width in [600.0, 892.0] {
                for hasLyrics in [false, true] {
                    preferences(language, ["playerLyricsDisplayMode": hasLyrics ? "always" : "never"])
                    try render(PlayerView(model: hasLyrics ? availableLyrics : absentLyrics), width: width,
                               height: width == 600 ? 360 : 650,
                               name: "player-boundary-\(language)-\(Int(width))-\(hasLyrics ? "lyrics" : "plain")")
                }
            }
        }

        // Keep a real host alive while preferences change. A hidden lyric pane
        // must preserve its scroll view/state; a nonzero progress value makes
        // layout/track-fill mismatches visible in the intermediate snapshots.
        var liveSamples: [[String: Any]] = []
        func updateLivePreference(_ key: String, _ value: Any) {
            let defaults = UserDefaults.standard
            var values = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            values[key] = value
            defaults.willChangeValue(forKey: key)
            defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
            defaults.didChangeValue(forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        func nativeScrollViews(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap { nativeScrollViews(in: $0) }
        }
        for width in [600.0, 892.0] {
            preferences("en", ["playerLyricsDisplayMode": "always"])
            let host = NSHostingView(rootView: PlayerView(model: availableLyrics).appTypography()
                .environment(\.colorScheme, .dark).environment(\.locale, Locale(identifier: "en")))
            let height: CGFloat = width == 600 ? 360 : 650
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.alphaValue = 0; window.orderBack(nil)
            window.setContentSize(NSSize(width: width, height: height))
            RunLoop.current.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded()
            let initialScrollViews = Set(nativeScrollViews(in: host).map(ObjectIdentifier.init))
            precondition(!initialScrollViews.isEmpty, "No native lyrics scroll view in live player fixture")
            func saveLive(_ name: String) throws {
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No live render surface") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No live image") }
                try png.write(to: output.appendingPathComponent(name + ".png")); renderedCases += 1
            }
            try saveLive("live-\(Int(width))-initial")
            let changes: [(key: String, value: Any, label: String)] = [
                ("playerShowsProgress", false, "progress-off"), ("playerShowsProgress", true, "progress-on"),
                ("playerLyricsDisplayMode", "never", "lyrics-off"), ("playerLyricsDisplayMode", "always", "lyrics-on")
            ]
            for change in changes {
                updateLivePreference(change.key, change.value)
                for frame in 1...8 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.04)); host.layoutSubtreeIfNeeded()
                    let currentScrollViews = Set(nativeScrollViews(in: host).map(ObjectIdentifier.init))
                    precondition(initialScrollViews.isSubset(of: currentScrollViews),
                                 "Toggling sections recreated the active lyric scroll view")
                    precondition(host.bounds.width <= width + 1 && host.bounds.height <= window.frame.height + 1,
                                 "Live player grew beyond its native window while toggling sections")
                    precondition(window.aspectRatio == .zero && window.contentAspectRatio == .zero,
                                 "Wide section toggle introduced an aspect lock")
                    liveSamples.append(["width": width, "change": change.label, "frame": frame,
                        "hostBounds": NSStringFromRect(host.bounds), "scrollViewCount": currentScrollViews.count,
                        "originalScrollViewsRetained": true])
                    if frame == 4 && ["progress-on", "lyrics-off"].contains(change.label) {
                        try saveLive("live-\(Int(width))-\(change.label)-mid")
                    }
                }
            }
            try saveLive("live-\(Int(width))-restored")
            window.contentView = nil; window.close()
        }
        let liveData = try JSONSerialization.data(withJSONObject: liveSamples, options: [.prettyPrinted, .sortedKeys])
        try liveData.write(to: output.appendingPathComponent("live-player-layout-check.json"))
        var captionState = state
        captionState.title = "touch her"
        captionState.artist = "Question...? (Explicit)-Taylor Swift"
        captionState.album = "Midnights"
        captionState.lyricsText = "[ti:Question...? (Explicit)]\n[ar:Taylor Swift]\n[00:00.00]Do you wish you could still touch her"
        let captionModel = ReceiverModel.preview(captionState, artwork: artwork, root: stateRoot)
        let correctedLabels = captionModel.correctedDisplayMetadata
        precondition(correctedLabels.title == "Question...? (Explicit)" && correctedLabels.artist == "Taylor Swift")
        let rawPresentation = MediaPresentation(captionState)
        let correctedPresentation = MediaPresentation(captionState, metadata: correctedLabels)
        precondition(rawPresentation?.title == "touch her" && correctedPresentation?.title == correctedLabels.title)
        precondition(correctedPresentation?.trackID == captionState.trackId && captionModel.snapshot?.title == "touch her",
                     "Display correction changed raw control metadata")
        preferences("zh-Hans", ["uiCorrectLyricTitles": true, "playerLyricsDisplayMode": "never"])
        try render(ReceiverPanel(model: captionModel), width: 280, height: 180, name: "menu-corrected-title")
        try render(PlayerView(model: captionModel), width: 760, height: 400, name: "player-corrected-title")

        var metadataGapResult: Result<Void, Error>?
        Task { @MainActor in
            do {
                try await LyricsMetadataGapChecks.run(initialState: state, root: stateRoot)
                metadataGapResult = .success(())
            } catch { metadataGapResult = .failure(error) }
        }
        let metadataGapDeadline = Date().addingTimeInterval(5)
        while metadataGapResult == nil && Date() < metadataGapDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        guard let metadataGapResult else { fatalError("Metadata gap check did not finish") }
        try metadataGapResult.get()
        precondition(PlayerAppearance.time(3_661_000) == "1:01:01")
        precondition(PlayerAppearance.hex(Color(nsColor: PlayerAppearance.nsColor(hex: "#FF9F0A"))) == "#FF9F0A")
        precondition(PlayerAppearance.hex(Color(nsColor: PlayerAppearance.nsColor(hex: "invalid"))) == PlayerAppearance.defaultCustomHex)
        print("PASS: \(renderedCases) production view renders including the original 50 cases, custom/missing fonts and 600/892 wide boundaries")
        print("PASS: \(liveSamples.count) live-host samples retained the lyric scroll view and native bounds through progress/lyrics toggles")
        print("Preview-only process: no receiver start, system media or user preferences changed")
    }
}
