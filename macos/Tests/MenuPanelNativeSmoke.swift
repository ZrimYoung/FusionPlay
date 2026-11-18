import AppKit
import ScreenCaptureKit
import SwiftUI

@main
struct MenuPanelNativeSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        Task { @MainActor in
            do {
                try await runChecks()
                print("PASS: native menu materials, retained host, positioning, entry points, quit sheet and dismissal")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Native menu check failed: \(error)\n".utf8))
                exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func pause(_ interval: Double = 0.2) async {
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    @MainActor private static func runChecks() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let root = output.appendingPathComponent("isolated-state")
        let receiver = try Receiver(dataDirectory: root.appendingPathComponent("data").path)
        defer { receiver.stop() }
        var state = receiver.snapshot()
        state.controlsAvailable = true; state.phase = .playing
        state.trackId = "native-menu-check"; state.title = "A Clear Morning"
        state.artist = "FusionPlay"; state.album = "Glass Preview"
        state.durationMs = 240_000; state.positionMs = 72_000
        let art = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { bounds in
            NSGradient(colors: [.systemPink, .systemOrange, .systemBlue])!.draw(in: bounds, angle: 45)
            return true
        }
        let model = ReceiverModel.preview(state, artwork: art, root: root)
        let defaults = UserDefaults(suiteName: "tech.zrim.fusionplay.menu-native-check.isolated")!
        func preference(_ style: MenuPanelBackgroundStyle, visible: Bool = true) {
            defaults.setVolatileDomain([
                "showMenuBarIcon": visible, "appLanguage": "en",
                MenuPanelBackgroundStyle.storageKey: style.rawValue
            ], forName: UserDefaults.argumentDomain)
        }
        preference(.liquidGlass)
        var destinations: [String] = []
        let menu = MenuPanelController(model: model, openWindow: { destinations.append($0) }, defaults: defaults)
        defer { menu.invalidate() }
        let host = menu.testHostIdentity
        precondition(menu.testHasStatusItem)
        precondition(!menu.testPanel.isOpaque && menu.testPanel.backgroundColor.alphaComponent == 0)
        precondition(menu.testPanel.level == .statusBar)

        for anchor in [NSRect(x: 0, y: 880, width: 20, height: 24), NSRect(x: 1190, y: 880, width: 20, height: 24)] {
            let visible = NSRect(x: 0, y: 0, width: 1200, height: 880)
            let rect = MenuPanelController.menuFrame(anchor: anchor, visibleFrame: visible,
                                                     size: NSSize(width: 280, height: 190))
            precondition(visible.contains(rect), "Menu escaped visible screen")
            precondition(rect.maxY <= anchor.minY - 6, "Menu overlapped its status item")
        }

        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.level = .floating
        let backdropView = CheckBackdrop()
        backdrop.contentView = backdropView
        defer { backdrop.orderOut(nil); backdrop.close() }
        var captures: [[String: Any]] = []
        for light in [false, true] {
            backdropView.light = light; backdropView.needsDisplay = true
            for style in MenuPanelBackgroundStyle.choices {
                preference(style); menu.syncPreferences(); menu.show()
                await pause(0.3)
                precondition(menu.testPanel.isVisible, "Menu failed to open")
                precondition(menu.testHostIdentity == host, "Changing style discarded menu state")
                precondition(menu.testPanel.frame.width == 280)
                precondition(menu.testPanel.frame.height >= 130 && menu.testPanel.frame.height < 350,
                             "Menu sizing did not settle")
#if compiler(>=6.2)
                if #available(macOS 26.0, *), style == .liquidGlass,
                   !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                    guard let glass = menu.testMaterial as? NSGlassEffectView else { fatalError("Native clear glass missing") }
                    precondition(glass.style == .clear && glass.tintColor == nil)
                    precondition(glass.contentView != nil)
                } else {
                    precondition(menu.testMaterial is NSVisualEffectView)
                }
#else
                precondition(menu.testMaterial is NSVisualEffectView)
#endif
                backdrop.setFrame(menu.testPanel.frame.insetBy(dx: -80, dy: -70), display: true)
                backdrop.orderFront(nil); menu.testPanel.orderFront(nil)
                await pause(0.3)
                let name = "menu-\(style.rawValue)-\(light ? "light" : "dark")"
                captures.append(try await capture(menu.testPanel, name: name, output: output))
                menu.close()
                precondition(!menu.testPanel.isVisible)
            }
        }

        for _ in 0..<8 {
            menu.toggle(); await pause(0.03)
            precondition(menu.testPanel.isVisible)
            menu.toggle(); precondition(!menu.testPanel.isVisible)
        }
        preference(.liquidGlass, visible: false); menu.syncPreferences()
        precondition(!menu.testHasStatusItem && !menu.testPanel.isVisible)
        preference(.liquidGlass); menu.syncPreferences(); menu.show(); await pause()
        precondition(menu.testHasStatusItem && menu.testPanel.isVisible && menu.testHostIdentity == host)

        let alert = NSAlert()
        alert.messageText = "Quit FusionPlay?"
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: menu.testPanel) { _ in }
        await pause()
        precondition(menu.testPanel.attachedSheet != nil && menu.testPanel.isVisible,
                     "Quit confirmation closed its parent menu")
        menu.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: menu.testPanel))
        await pause()
        precondition(menu.testPanel.isVisible, "Focus change dismissed pending confirmation")
        menu.testPanel.endSheet(alert.window, returnCode: .cancel)
        await pause()

        menu.close(); menu.show(); await pause()
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: menu.testPanel.windowNumber, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        NSApp.postEvent(escape, atStart: false)
        await pause()
        precondition(!menu.testPanel.isVisible, "Escape did not close menu")

        menu.show(); await pause()
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 20, y: 20),
                                       modifierFlags: [], timestamp: 0, windowNumber: backdrop.windowNumber,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        NSApp.postEvent(click, atStart: false)
        await pause()
        precondition(!menu.testPanel.isVisible, "Outside click did not close menu")

        menu.show(); menu.testOpenDestination("settings")
        precondition(destinations == ["settings"] && !menu.testPanel.isVisible)
        menu.setOpenWindowAction { destinations.append("updated:" + $0) }
        menu.show(); menu.testOpenDestination("player")
        precondition(destinations == ["settings", "updated:player"] && !menu.testPanel.isVisible)
        menu.invalidate(); menu.invalidate()
        precondition(!menu.testHasStatusItem && !menu.testPanel.isVisible)
        menu.show(); precondition(!menu.testPanel.isVisible)
        try JSONSerialization.data(withJSONObject: ["passed": true, "captures": captures,
            "receiverStarted": false, "realPreferencesChanged": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("native-menu-check.json"), options: .atomic)
    }

    @MainActor private static func capture(_ window: NSWindow, name: String, output: URL) async throws -> [String: Any] {
        // Capture only this check application's own panel. Do not enumerate or
        // record other applications or the user's desktop.
        if #available(macOS 14.4, *) {
            let content = try await SCShareableContent.currentProcess
            guard window.windowNumber > 0,
                  let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
            else { return ["name": name, "captured": false] }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * window.backingScaleFactor)
            config.height = Int(window.frame.height * window.backingScaleFactor)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            var filter = SCContentFilter(desktopIndependentWindow: own)
            var captureMode = "window-only"
            // If permission already exists, composite only this process's own
            // synthetic backdrop and panel. Never request broader permission.
            if CGPreflightScreenCaptureAccess(),
               let display = content.displays.first(where: { $0.frame.intersects(own.frame) }) {
                filter = SCContentFilter(display: display, including: content.windows)
                filter.includeMenuBar = false
                config.sourceRect = CGRect(x: own.frame.minX - display.frame.minX,
                                           y: own.frame.minY - display.frame.minY,
                                           width: own.frame.width, height: own.frame.height)
                captureMode = "own-windows-composited"
            }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
            return ["name": name, "captured": true, "mode": captureMode]
        }
        return ["name": name, "captured": false]
    }
}

private final class CheckBackdrop: NSView {
    var light = false
    override func draw(_ dirtyRect: NSRect) {
        let colors: [NSColor] = light ? [.white, .systemYellow, .white] : [.systemIndigo, .black, .systemTeal]
        NSGradient(colors: colors)!.draw(in: bounds, angle: 20)
        (light ? NSColor.black : NSColor.white).withAlphaComponent(0.25).setStroke()
        let path = NSBezierPath(); path.lineWidth = 2
        for x in stride(from: CGFloat(0), to: bounds.width, by: 32) {
            path.move(to: CGPoint(x: x, y: 0)); path.line(to: CGPoint(x: x + 100, y: bounds.height))
        }
        path.stroke()
    }
}
