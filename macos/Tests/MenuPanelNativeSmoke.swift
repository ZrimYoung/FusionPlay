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
                let visual = ProcessInfo.processInfo.environment["FUSIONPLAY_MENU_VISUAL_CHECK"] == "1"
                let focus = ProcessInfo.processInfo.environment["FUSIONPLAY_MENU_FOCUS_CHECK"] == "1"
                if focus {
                    print("PASS: menu opens without automatic cover focus, Tab reaches controls, keyboard activates cover, and reopening clears stale focus")
                    exit(0)
                }
                print(visual
                    ? "PASS: visual native menu materials, retained host, positioning, entry points, quit sheet and dismissal"
                    : "PASS: hidden native menu materials, retained host, positioning, shadows and preference compatibility")
                if !visual {
                    print("Hidden mode: no windows ordered; interactive opening/dismissal, quit-sheet and screenshot checks skipped")
                }
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
        let visual = ProcessInfo.processInfo.environment["FUSIONPLAY_MENU_VISUAL_CHECK"] == "1"
        let focus = ProcessInfo.processInfo.environment["FUSIONPLAY_MENU_FOCUS_CHECK"] == "1"
        let interactive = visual || focus
        func preference(_ style: MenuPanelBackgroundStyle, visible: Bool? = nil) {
            defaults.setVolatileDomain([
                "showMenuBarIcon": visible ?? interactive, "appLanguage": "en",
                MenuPanelBackgroundStyle.storageKey: style.rawValue
            ], forName: UserDefaults.argumentDomain)
        }
        precondition(MenuPanelBackgroundStyle(rawValue: "liquid") == .liquidGlass,
                     "An explicit previous clear preference must remain clear")
        precondition(MenuPanelBackgroundStyle.resolve("liquid") == (MenuPanelBackgroundStyle.supportsLiquidGlass ? .liquidGlass : .frosted))
        if MenuPanelBackgroundStyle.supportsLiquidGlass {
            precondition(MenuPanelBackgroundStyle.defaultValue == .regularGlass)
            precondition(MenuPanelBackgroundStyle.choices.map(\.rawValue) == ["frosted", "regular", "liquid"])
        } else {
            precondition(MenuPanelBackgroundStyle.defaultValue == .frosted)
            precondition(MenuPanelBackgroundStyle.choices == [.frosted])
        }
        preference(.liquidGlass)
        var destinations: [String] = []
        let menu = MenuPanelController(model: model, openWindow: { destinations.append($0) }, defaults: defaults)
        defer { menu.invalidate() }
        // A transparent window can still take keyboard focus when made key.
        // The default mode never calls show()/makeKeyAndOrderFront, creates no
        // status item, never presents a sheet and never asks for screen access.
        menu.testPanel.alphaValue = interactive ? 1 : 0
        menu.testPanel.ignoresMouseEvents = !interactive
        let host = menu.testHostIdentity
        precondition(menu.testHasStatusItem == interactive)
        precondition(!menu.testPanel.isOpaque && menu.testPanel.backgroundColor.alphaComponent == 0)
        precondition(menu.testPanel.level == .statusBar)

        for anchor in [NSRect(x: 0, y: 880, width: 20, height: 24), NSRect(x: 1190, y: 880, width: 20, height: 24)] {
            let visible = NSRect(x: 0, y: 0, width: 1200, height: 880)
            let rect = MenuPanelController.menuFrame(anchor: anchor, visibleFrame: visible,
                                                     size: NSSize(width: 280, height: 190))
            precondition(visible.contains(rect), "Menu escaped visible screen")
            precondition(rect.maxY <= anchor.minY - 6, "Menu overlapped its status item")
        }

        func validateMaterial(_ style: MenuPanelBackgroundStyle) {
#if compiler(>=6.2)
            if #available(macOS 26.0, *), style != .frosted,
               !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                guard let glass = menu.testMaterial as? NSGlassEffectView else { fatalError("Native glass missing") }
                precondition(glass.style == (style == .regularGlass ? .regular : .clear) && glass.tintColor == nil)
                precondition(menu.testPanel.contentView === glass)
                precondition(glass.contentView.map(ObjectIdentifier.init) == host,
                             "Glass must directly host the retained controls, without another material")
                precondition(!menu.testPanel.hasShadow, "Glass retained a second window shadow")
            } else {
                precondition(menu.testMaterial is NSVisualEffectView && menu.testPanel.hasShadow)
            }
#else
            precondition(menu.testMaterial is NSVisualEffectView && menu.testPanel.hasShadow)
#endif
            precondition(defaults.string(forKey: MenuPanelBackgroundStyle.storageKey) == style.rawValue,
                         "Changing native material rewrote the user's selection")
        }

        if focus {
            // This opt-in check briefly opens only this isolated preview; it
            // never captures the desktop, starts a receiver or edits user settings.
            menu.show(); await pause(0.3)
            precondition(menu.testPanel.isVisible)
            precondition(menu.testPanel.firstResponder === menu.testPanel,
                         "Opening the menu selected its first control automatically")
            menu.testPanel.selectNextKeyView(nil)
            await pause(0.1)
            precondition(menu.testPanel.firstResponder != nil && menu.testPanel.firstResponder !== menu.testPanel,
                         "Tab cannot enter the menu controls")
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let space = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: menu.testPanel.windowNumber, context: nil, characters: " ",
                    charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
                NSApp.postEvent(space, atStart: false)
            }
            await pause(0.2)
            precondition(destinations == ["player"] && !menu.testPanel.isVisible,
                         "Keyboard activation of the cover failed")
            precondition(model.miniPlayerRequest == 1,
                         "The cover no longer requests the mini player")
            menu.show(); await pause(0.2)
            precondition(menu.testPanel.firstResponder === menu.testPanel,
                         "Reopening the menu restored a stale control highlight")
            menu.close()
            try JSONSerialization.data(withJSONObject: ["passed": true, "mode": "keyboard-focus",
                "tabNavigation": true, "coverKeyboardActivation": true, "receiverStarted": false,
                "realPreferencesChanged": false], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-menu-focus-check.json"), options: .atomic)
            return
        }

        if !visual {
            let previousKey = NSApp.keyWindow
            var materials: [[String: Any]] = []
            for style in MenuPanelBackgroundStyle.choices {
                preference(style, visible: false)
                menu.syncPreferences()
                // Even orderBack may choose a key window during AppKit startup.
                // Inspect the native hierarchy without ordering any window.
                menu.testPanel.contentView?.layoutSubtreeIfNeeded()
                await pause(0.12)
                precondition(!menu.testPanel.isVisible && menu.testPanel.alphaValue == 0)
                precondition(!menu.testPanel.isKeyWindow && NSApp.keyWindow === previousKey,
                             "Hidden menu check took keyboard focus")
                precondition(!menu.testHasStatusItem && menu.testHostIdentity == host)
                validateMaterial(style)
                materials.append(["style": style.rawValue, "shadow": menu.testPanel.hasShadow,
                                  "visible": menu.testPanel.isVisible, "alpha": menu.testPanel.alphaValue])
                menu.close()
                precondition(!menu.testPanel.isVisible)
            }
            menu.invalidate(); menu.invalidate()
            precondition(!menu.testHasStatusItem && !menu.testPanel.isVisible)
            try JSONSerialization.data(withJSONObject: ["passed": true, "mode": "hidden-materials",
                "materials": materials, "interactiveChecksRun": false, "captures": [],
                "receiverStarted": false, "realPreferencesChanged": false, "keyWindowUnchanged": true,
                "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                "materialsChecked": MenuPanelBackgroundStyle.choices.map(\.rawValue)], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-menu-check.json"), options: .atomic)
            return
        }

        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.alphaValue = visual ? 1 : 0
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
                validateMaterial(style)
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
        alert.window.alphaValue = visual ? 1 : 0
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
        try JSONSerialization.data(withJSONObject: ["passed": true, "mode": "visual-interactive", "interactiveChecksRun": true, "captures": captures,
            "receiverStarted": false, "realPreferencesChanged": false, "materialsChecked": MenuPanelBackgroundStyle.choices.map(\.rawValue)], options: [.prettyPrinted, .sortedKeys])
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
