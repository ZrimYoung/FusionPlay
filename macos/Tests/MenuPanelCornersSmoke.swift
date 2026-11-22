import AppKit
import QuartzCore

@main struct MenuPanelCornersSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.finishLaunching()
        app.setActivationPolicy(.prohibited)
        do { try check(); exit(0) }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func check() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "MenuPanelCorners", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let defaults = UserDefaults(suiteName: "tech.zrim.fusionplay.menu-corners-check")!
        let state = Snapshot(phase: .playing, title: "Synthetic corner probe", artist: "Preview", album: "Check",
            trackId: "corner-check", artworkUrl: "", lyricsText: "", durationMs: 180_000, positionMs: 10_000,
            controlsAvailable: true, volume: 50, message: "", address: "", output: "", queueMs: 0,
            outputLatencyMs: 0, scheduleErrorMs: 0, underruns: 0, droppedFrames: 0, resyncs: 0)
        let model = ReceiverModel.preview(state, artwork: nil, root: URL(fileURLWithPath: CommandLine.arguments[1]))
        defaults.setVolatileDomain(["showMenuBarIcon": false,
            MenuPanelBackgroundStyle.storageKey: MenuPanelBackgroundStyle.frosted.rawValue], forName: UserDefaults.argumentDomain)
        let menu = MenuPanelController(model: model, openWindow: { _ in }, defaults: defaults)
        defer { menu.invalidate() }
        let hostIdentity = menu.testHostIdentity
        menu.testPanel.alphaValue = 0
        var samples = 0
        for reduced in [false, true] {
            for style in MenuPanelBackgroundStyle.allCases {
                defaults.setVolatileDomain(["showMenuBarIcon": false,
                    MenuPanelBackgroundStyle.storageKey: style.rawValue], forName: UserDefaults.argumentDomain)
                menu.testReducedTransparencyOverride = reduced
                menu.syncPreferences()
                guard let surface = menu.testMaterial, let layer = surface.layer else {
                    throw NSError(domain: "Missing menu surface layer", code: 1)
                }
                try require(layer.masksToBounds && layer.cornerRadius == 18 && !layer.isOpaque,
                            "The complete material/hosting surface is not transparently rounded")
                try require(!menu.testPanel.isOpaque && menu.testPanel.backgroundColor.alphaComponent == 0,
                            "Native window became opaque")
                try require(menu.testHostIdentity == hostIdentity, "Changing materials recreated hosted controls")
                let nativeGlass = MenuPanelBackgroundStyle.supportsLiquidGlass && style != .frosted && !reduced
#if compiler(>=6.2)
                if #available(macOS 26.0, *), nativeGlass {
                    guard let glass = surface as? NSGlassEffectView else { throw NSError(domain: "Missing glass", code: 1) }
                    try require(glass.style == (style == .regularGlass ? .regular : .clear) && glass.tintColor == nil,
                                "Corner clipping changed native glass appearance")
                    try require(glass.contentView.map(ObjectIdentifier.init) == hostIdentity,
                                "Glass no longer directly contains the retained controls")
                } else {
                    try require(surface is NSVisualEffectView, "Fallback material changed")
                }
#else
                try require(surface is NSVisualEffectView, "Legacy fallback material changed")
#endif
                try require(menu.testPanel.hasShadow == !nativeGlass, "Window shadow policy changed")
                for height in [CGFloat(120), 174, 260] {
                    menu.testSetHeight(height)
                    surface.layoutSubtreeIfNeeded()
                    // Add an opaque rectangular descendant to the actual native
                    // root layer. Render only this isolated view tree in memory;
                    // no window, desktop or other application is captured.
                    let solid = CALayer(); solid.frame = layer.bounds
                    solid.backgroundColor = NSColor.white.cgColor
                    layer.addSublayer(solid)
                    defer { solid.removeFromSuperlayer() }
                    let width = Int(layer.bounds.width), rows = Int(layer.bounds.height)
                    try require(width >= 100 && rows >= 100, "Surface failed to follow native menu sizing")
                    let stride = width * 4
                    let data = UnsafeMutableRawPointer.allocate(byteCount: stride * rows, alignment: 16)
                    defer { data.deallocate() }
                    data.initializeMemory(as: UInt8.self, repeating: 0, count: stride * rows)
                    guard let context = CGContext(data: data, width: width, height: rows, bitsPerComponent: 8,
                        bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                        throw NSError(domain: "No corner bitmap context", code: 1)
                    }
                    layer.render(in: context)
                    let bytes = data.assumingMemoryBound(to: UInt8.self)
                    func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * stride + x * 4 + 3] }
                    for (x, y) in [(1, 1), (width - 2, 1), (1, rows - 2), (width - 2, rows - 2)] {
                        try require(alpha(x, y) == 0, "Opaque backing content escaped a menu corner: \(style), reduced=\(reduced)")
                    }
                    try require(alpha(width / 2, rows / 2) > 240, "Rounded mask removed the interior content")
                    samples += 1
                }
                try require(defaults.string(forKey: MenuPanelBackgroundStyle.storageKey) == style.rawValue,
                            "Corner repair migrated a user material preference")
            }
        }
        try require(!menu.testPanel.isVisible && !menu.testHasStatusItem && menu.testPanel.alphaValue == 0
                    && !NSRunningApplication.current.isActive && NSApp.activationPolicy() == .prohibited
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost,
                    "Corner check showed a window or changed foreground focus")
        print("PASS: \(samples) silent material/reduced-transparency/height combinations; actual root-layer corners alpha-zero with opaque descendant, retained controls, glass/fallback/shadow and preferences preserved")
    }
}
