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
                "showDockIcon": true, "showMenuBarIcon": true, "playerWindowPinned": false, "playerShowsPinButton": false]
            values.merge(extras) { _, new in new }
            UserDefaults.standard.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
        }
        @MainActor func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
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
                let expectedMinimum: CGFloat = width < 600 ? width + 136 : 260
                FileHandle.standardError.write(Data("native minimum \(name): \(window.contentMinSize), titlebar \(titlebarInset)\n".utf8))
                precondition(window.contentMinSize.width <= 260 && window.contentMinSize.height <= expectedMinimum + titlebarInset,
                             "Player minimum grew with content: " + name)
                precondition(window.contentMinSize.height >= expectedMinimum,
                             "Square cover leaves no minimum lyric area: " + name)
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
        for size in [NSSize(width: 260, height: 260), NSSize(width: 420, height: 420), NSSize(width: 760, height: 400)] {
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
            for size in [NSSize(width: 260, height: 440), NSSize(width: 420, height: 700), NSSize(width: 760, height: 400), NSSize(width: 840, height: 300), NSSize(width: 1200, height: 800)] {
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
        precondition(PlayerAppearance.time(3_661_000) == "1:01:01")
        precondition(PlayerAppearance.hex(Color(nsColor: PlayerAppearance.nsColor(hex: "#FF9F0A"))) == "#FF9F0A")
        precondition(PlayerAppearance.hex(Color(nsColor: PlayerAppearance.nsColor(hex: "invalid"))) == PlayerAppearance.defaultCustomHex)
        print("PASS: \(count + 3) production view renders; two languages, minimum/default settings sizes, player sizes, hidden sections, custom color and lyrics states")
        print("Preview-only process: no receiver start, system media or user preferences changed")
    }
}
