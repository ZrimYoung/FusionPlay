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
                "playerShowsTransport": true, "playerShowsProgress": true, "playerProgressColorMode": "white",
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
        precondition(PlayerAppearance.time(3_661_000) == "1:01:01")
        precondition(PlayerAppearance.hex(Color(nsColor: PlayerAppearance.nsColor(hex: "#FF9F0A"))) == "#FF9F0A")
        precondition(PlayerAppearance.hex(Color(nsColor: PlayerAppearance.nsColor(hex: "invalid"))) == PlayerAppearance.defaultCustomHex)
        print("PASS: \(count + 3) production view renders; two languages, minimum/default settings sizes, player sizes, hidden sections and custom color")
        print("Preview-only process: no receiver start, system media or user preferences changed")
    }
}
