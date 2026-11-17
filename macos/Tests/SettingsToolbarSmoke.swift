import AppKit
import Darwin
import ScreenCaptureKit
import SwiftUI

/// Uses a real SwiftUI Window scene: an NSHostingView-only render does not
/// install the scene's native toolbar and cannot detect duplicate sidebar items.
@main struct SettingsToolbarSmoke: App {
    @NSApplicationDelegateAdaptor(ToolbarSmokeDelegate.self) private var delegate
    @StateObject private var model: ReceiverModel
    @AppStorage("appLanguage") private var language = "zh-Hans"

    init() {
        precondition(Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.toolbar-check")
        let defaults = UserDefaults.standard
        // Registration defaults remain writable by AppStorage. Argument-domain
        // overrides would hide subsequent writes and prevent a genuine toggle.
        defaults.removeObject(forKey: "settingsSidebarVisible")
        defaults.removeObject(forKey: "appLanguage")
        defaults.setVolatileDomain(["settingsSidebarVisible": true, "appLanguage": "zh-Hans"],
                                  forName: UserDefaults.registrationDomain)
        defaults.setVolatileDomain(["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false, "uiFontFamily": "", "uiFontWeight": 400],
                                  forName: UserDefaults.argumentDomain)
        let state = Snapshot(phase: .ready, title: "", artist: "", album: "", trackId: "", artworkUrl: "",
            lyricsText: "", durationMs: nil, positionMs: nil, controlsAvailable: false, volume: 50,
            message: "", address: "", output: "", queueMs: 0, outputLatencyMs: 0, scheduleErrorMs: 0,
            underruns: 0, droppedFrames: 0, resyncs: 0)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FUSIONPLAY_TOOLBAR_CHECK_ROOT"]!, isDirectory: true)
        _model = StateObject(wrappedValue: ReceiverModel.preview(state, artwork: nil, root: root))
    }
    var body: some Scene {
        Window("FusionPlay Toolbar Check", id: "toolbar-check") {
            SettingsPanel(model: model)
                .appTypography()
                .environment(\.locale, Locale(identifier: language))
                .background(ToolbarWindowProbe().frame(width: 0, height: 0))
        }.defaultSize(width: 820, height: 620)
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified(showsTitle: false))
            .commands { PlayerFullScreenCommands() }
    }
}

final class ToolbarSmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 55) {
            FileHandle.standardError.write(Data("FAIL: native toolbar check timed out\n".utf8))
            exit(1)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private struct ToolbarWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private var started = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !started else { return }
            started = true
            // Keep this isolated synthetic scene behind the user's receiver.
            window.alphaValue = 1
            window.setContentSize(NSSize(width: 820, height: 620))
            window.orderBack(nil)
            Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
                await inspect(window)
            }
        }
        @MainActor private func inspect(_ window: NSWindow) async {
            func fullScreenShortcuts(in menu: NSMenu?) -> [NSMenuItem] {
                menu?.items.flatMap { item -> [NSMenuItem] in
                    let modifiers = item.keyEquivalentModifierMask.intersection([.control, .command, .option, .shift])
                    let own = item.keyEquivalent == "f" && modifiers == [.control, .command] ? [item] : []
                    return own + fullScreenShortcuts(in: item.submenu)
                } ?? []
            }
            precondition(fullScreenShortcuts(in: NSApp.mainMenu).count == 1,
                         "Fullscreen shortcut missing or duplicated in the actual SwiftUI menu")
            // Cancel before the newly created task gets its first actor turn.
            // An obsolete request must not make an already settled header clear.
            let cancelledMotion = SettingsNavigationMotion(expanded: true)
            cancelledMotion.move(to: false, reduceMotion: false)
            cancelledMotion.settle(expanded: true)
            try? await Task.sleep(nanoseconds: 30_000_000)
            precondition(cancelledMotion.layoutExpanded && cancelledMotion.headerExpanded
                         && cancelledMotion.headerOpacity == 1 && cancelledMotion.sidebarOpacity == 1
                         && !cancelledMotion.isTransitioning, "Cancelled motion changed a settled header")
            cancelledMotion.move(to: false, reduceMotion: true)
            precondition(!cancelledMotion.layoutExpanded && !cancelledMotion.headerExpanded
                         && cancelledMotion.headerOpacity == 1 && cancelledMotion.sidebarOpacity == 0
                         && !cancelledMotion.isTransitioning, "Reduce Motion must settle synchronously")
            cancelledMotion.move(to: true, reduceMotion: false)
            cancelledMotion.move(to: false, reduceMotion: true)
            try? await Task.sleep(nanoseconds: 30_000_000)
            precondition(!cancelledMotion.layoutExpanded && !cancelledMotion.headerExpanded
                         && cancelledMotion.headerOpacity == 1 && !cancelledMotion.isTransitioning,
                         "A cancelled task overrode the latest Reduce Motion target")
            var observations: [[String: Any]] = []
            var screenshots: [[String: Any]] = []
            var waits: [[String: Any]] = []
            var expectedPage = 0
            var expectedLanguage = "zh-Hans"
            func expectedNames() -> [String] {
                expectedLanguage == "en" ? ["Receiver", "Appearance", "Advanced", "About"] : ["接收", "外观", "高级", "关于"]
            }
            func items(_ id: String) -> [NSToolbarItem] {
                window.toolbar?.items.filter { $0.itemIdentifier.rawValue == id } ?? []
            }
            func sidebarItems() -> [NSToolbarItem] {
                window.toolbar?.items.filter {
                    let id = $0.itemIdentifier.rawValue.lowercased()
                    return id.contains("sidebar") && !id.contains("tracking") && !id.contains("separator")
                } ?? []
            }
            func find<T: NSView>(_ type: T.Type, in view: NSView?, matching: (T) -> Bool = { _ in true }) -> T? {
                guard let view else { return nil }
                if let match = view as? T, matching(match) { return match }
                return view.subviews.compactMap { find(type, in: $0, matching: matching) }.first
            }
            func sidebarTable() -> NSTableView? {
                find(NSTableView.self, in: window.contentView) { $0.numberOfRows == ReceiverSettingsPage.allCases.count }
            }
            func sidebarMarker() -> NSView? {
                find(NSView.self, in: window.contentView) { $0.identifier?.rawValue == "fusionplay.settings.sidebar.viewport" }
            }
            func viewportWidth() -> CGFloat { sidebarMarker()?.bounds.width ?? -1 }
            func motionState() -> String? {
                guard let marker = sidebarMarker(), marker.responds(to: NSSelectorFromString("accessibilityValue")) else { return nil }
                return marker.value(forKey: "accessibilityValue") as? String
            }
            func titleLabel() -> NSTextField? {
                find(NSTextField.self, in: items("fusionplay.settings.title").first?.view) {
                    $0.identifier?.rawValue == "fusionplay.settings.title.label"
                }
            }
            func tabs() -> NSSegmentedControl? {
                find(NSSegmentedControl.self, in: items("fusionplay.settings.pages").first?.view)
            }
            func sidebarControlMaxX() -> CGFloat? {
                guard var view = sidebarItems().first?.view else { return nil }
                while let parent = view.superview, String(describing: type(of: view)) != "NSToolbarItemViewer" { view = parent }
                return view.convert(view.bounds, to: nil).maxX
            }
            func ancestorRecords(_ view: NSView?) -> [[String: Any]] {
                var result: [[String: Any]] = []; var current = view
                while let view = current, result.count < 12 {
                    var info: [String: Any] = ["class": String(describing: type(of: view)),
                        "frame": NSStringFromRect(view.frame), "bounds": NSStringFromRect(view.bounds),
                        "alpha": view.alphaValue, "hidden": view.isHidden]
                    if let material = view as? NSVisualEffectView {
                        info["material"] = material.material.rawValue
                        info["blendingMode"] = material.blendingMode.rawValue
                        info["materialState"] = material.state.rawValue
                    }
                    result.append(info)
                    current = view.superview
                }
                return result
            }
            func windowGeometry() -> [String: Any] {
                ["windowFrame": NSStringFromRect(window.frame),
                 "contentViewFrame": window.contentView.map { NSStringFromRect($0.frame) } as Any? ?? NSNull(),
                 "contentViewBounds": window.contentView.map { NSStringFromRect($0.bounds) } as Any? ?? NSNull(),
                 "contentLayoutRect": NSStringFromRect(window.contentLayoutRect),
                 "styleMask": window.styleMask.rawValue, "titleVisibility": window.titleVisibility.rawValue,
                 "titlebarAppearsTransparent": window.titlebarAppearsTransparent,
                 "sidebarMarkerAncestors": ancestorRecords(sidebarMarker())]
            }
            func capture(_ state: String) async {
                // This public API restricts enumeration to content available to
                // this process without TCC consent. Never enumerate all windows,
                // request Screen Recording access, or capture the user's apps.
                guard #available(macOS 14.4, *) else {
                    screenshots.append(["state": state, "captured": false, "reason": "requires-macos-14.4"])
                    return
                }
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let motionBefore = motionState()
                let geometryBefore = windowGeometry()
                do {
                    let content = try await SCShareableContent.currentProcess
                    guard let ownWindow = content.windows.first(where: {
                        $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid()
                    }) else {
                        screenshots.append(["state": state, "captured": false, "reason": "own-window-not-shareable"])
                        return
                    }
                    let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(window.frame.width * window.backingScaleFactor)
                    configuration.height = Int(window.frame.height * window.backingScaleFactor)
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                        screenshots.append(["state": state, "captured": false, "reason": "png-encoding-failed"])
                        return
                    }
                    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FUSIONPLAY_TOOLBAR_CHECK_IMAGE_ROOT"]!, isDirectory: true)
                    let destination = root.appendingPathComponent("settings-toolbar-window-" + state + ".png")
                    try png.write(to: destination, options: .atomic)
                    screenshots.append(["state": state, "captured": true, "path": destination.path,
                        "width": image.width, "height": image.height,
                        "elapsedMs": (ProcessInfo.processInfo.systemUptime - requestedAt) * 1000,
                        "motionBefore": motionBefore as Any? ?? NSNull(), "motionAfter": motionState() as Any? ?? NSNull(),
                        "geometryBefore": geometryBefore, "geometryAfter": windowGeometry()])
                    print("Captured own native window: \(destination.lastPathComponent) \(image.width)x\(image.height)")
                } catch {
                    let error = error as NSError
                    screenshots.append(["state": state, "captured": false, "errorDomain": error.domain, "errorCode": error.code])
                    print("Own-window capture unavailable: \(error.domain) \(error.code); native hierarchy retained")
                }
            }
            func sample(_ stage: String, expanded: Bool? = nil) -> Bool {
                let titles = items("fusionplay.settings.title"), pageItems = items("fusionplay.settings.pages")
                let label = titleLabel(), control = tabs()
                let width = viewportWidth()
                let sideCount = sidebarItems().count
                var record: [String: Any] = ["stage": stage, "language": expectedLanguage, "expectedPage": expectedPage,
                    "expanded": expanded as Any? ?? NSNull(), "items": window.toolbar?.items.map(\.itemIdentifier.rawValue) ?? [],
                    "sidebarItems": sideCount, "sidebarWidth": width, "titleItems": titles.count, "pageItems": pageItems.count,
                    "sidebarSelectedRow": sidebarTable()?.selectedRow as Any? ?? NSNull(),
                    "sidebarRows": sidebarTable()?.numberOfRows as Any? ?? NSNull(), "windowWidth": window.frame.width,
                    "motionState": motionState() as Any? ?? NSNull(), "windowGeometry": windowGeometry()]
                // SwiftUI can retain an outgoing toolbar item during transition;
                // stable states below must have exactly one navigation form.
                var valid = window.toolbar != nil && sideCount == 1 && titles.count <= 1 && pageItems.count <= 1
                    && window.titleVisibility == .hidden
                if let expanded {
                    valid = valid && motionState() == "settled"
                    if expanded {
                        var plainAndAligned = false
                        if let label, let parent = label.superview, let buttonEnd = sidebarControlMaxX() {
                            let leading = label.convert(label.bounds, to: nil).minX
                            let expected = max(parent.convert(parent.bounds, to: nil).minX, width + 30)
                            let measured = ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width)
                            let drawable = label.cell?.drawingRect(forBounds: label.bounds).width ?? 0
                            plainAndAligned = label.stringValue == expectedNames()[expectedPage] && !label.isBordered && !label.drawsBackground
                                && abs(leading - expected) <= 1.5 && abs(leading - (width + 30)) <= 1.5
                                && leading >= buttonEnd - 0.5 && drawable >= measured && label.bounds.width >= measured + 4
                            record["titleText"] = label.stringValue; record["titleLeadingX"] = leading
                            record["expectedTitleLeadingX"] = expected; record["titleMeasuredWidth"] = measured
                            record["titleDrawableWidth"] = drawable; record["titleAncestors"] = ancestorRecords(label)
                        }
                        var noGlass = true
                        if #available(macOS 26.0, *) { noGlass = titles.first?.isBordered == false }
                        // SwiftUI's native List virtualizes text outside the
                        // public NSTableView cell tree. Verify its real rows and
                        // shared selection here; localized text is inspected in
                        // the own-window compositor screenshots.
                        record["sidebarLocalized"] = NSNull()
                        record["titlePlainAndAligned"] = plainAndAligned; record["titleNoGlass"] = noGlass
                        valid = valid && sidebarTable()?.numberOfRows == ReceiverSettingsPage.allCases.count && width >= 170 && titles.count == 1 && pageItems.isEmpty && plainAndAligned && noGlass
                    } else {
                        var tabsReadable = false
                        if let control, control.segmentCount == expectedNames().count, let buttonEnd = sidebarControlMaxX() {
                            let labels = (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
                            let measured = labels.map { ceil(($0 as NSString).size(withAttributes: [.font: control.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width) }
                            // Auto-width segments report zero through width(forSegment:).
                            // The production picker distributes its explicit total width.
                            let widths = (0..<control.segmentCount).map { index in
                                let explicit = control.width(forSegment: index)
                                return explicit > 0 ? explicit : control.bounds.width / CGFloat(control.segmentCount)
                            }
                            let frame = control.convert(control.bounds, to: nil)
                            tabsReadable = labels == expectedNames() && control.selectedSegment == expectedPage
                                && zip(widths, measured).allSatisfy { $0.0 >= $0.1 + 8 }
                                && frame.minX >= buttonEnd - 0.5 && frame.maxX <= window.frame.width - 4
                            record["tabLabels"] = labels; record["tabSelectedSegment"] = control.selectedSegment
                            record["tabWidths"] = widths; record["tabMeasuredTextWidths"] = measured
                            record["tabFrame"] = NSStringFromRect(frame); record["tabAncestors"] = ancestorRecords(control)
                        }
                        record["tabsReadable"] = tabsReadable
                        valid = valid && width <= 0.5 && titles.isEmpty && pageItems.count == 1 && tabsReadable
                    }
                }
                record["valid"] = valid; observations.append(record)
                print("\(stage): width=\(width), sidebar=\(sideCount), titles=\(titles.count), tabs=\(pageItems.count), valid=\(valid)")
                return valid
            }
            func finish(_ success: Bool, _ message: String) -> Never {
                let output = ProcessInfo.processInfo.environment["FUSIONPLAY_TOOLBAR_CHECK_OUTPUT"]!
                let result: [String: Any] = ["passed": success, "message": message, "observations": observations, "screenshots": screenshots, "waits": waits, "modelCancellationAndReduceMotion": "passed"]
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
                }
                print((success ? "PASS: " : "FAIL: ") + message); fflush(stdout)
                window.orderOut(nil); exit(success ? 0 : 1)
            }
            func toggle() -> Bool {
                guard let item = sidebarItems().first else { return false }
                if let button = find(NSButton.self, in: item.view, matching: { $0.isEnabled }) {
                    button.performClick(nil); return true
                }
                if let action = item.action, NSApp.sendAction(action, to: item.target, from: item) { return true }
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [.control, .command], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "s", charactersIgnoringModifiers: "s",
                    isARepeat: false, keyCode: 1) else { return false }
                return window.performKeyEquivalent(with: event)
            }
            func headerReady(_ expanded: Bool) -> Bool {
                guard motionState() == "settled", sidebarItems().count == 1 else { return false }
                if expanded {
                    guard viewportWidth() >= 170, items("fusionplay.settings.title").count == 1,
                          items("fusionplay.settings.pages").isEmpty, let label = titleLabel(),
                          label.stringValue == expectedNames()[expectedPage] else { return false }
                    return label.window === window && label.bounds.width >= 4 + ceil((label.stringValue as NSString).size(
                        withAttributes: [.font: label.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width)
                }
                guard viewportWidth() <= 0.5, items("fusionplay.settings.title").isEmpty,
                      items("fusionplay.settings.pages").count == 1, let control = tabs(), control.segmentCount == 4 else { return false }
                return control.selectedSegment == expectedPage
                    && (0..<4).map { control.label(forSegment: $0) ?? "" } == expectedNames()
            }
            func settle(expanded: Bool? = nil, timeout: TimeInterval = 2.5) async {
                let target = expanded ?? UserDefaults.standard.bool(forKey: "settingsSidebarVisible")
                let start = ProcessInfo.processInfo.systemUptime
                var readySamples = 0
                while ProcessInfo.processInfo.systemUptime - start < timeout {
                    guard sidebarItems().count == 1, items("fusionplay.settings.title").count <= 1,
                          items("fusionplay.settings.pages").count <= 1 else {
                        _ = sample("wait-duplicate-toolbar")
                        finish(false, "Duplicate toolbar navigation while waiting for motion")
                    }
                    readySamples = headerReady(target) ? readySamples + 1 : 0
                    if readySamples >= 2 {
                        waits.append(["expanded": target, "elapsedMs": (ProcessInfo.processInfo.systemUptime - start) * 1000,
                            "motionState": motionState() as Any? ?? NSNull(), "sidebarWidth": viewportWidth()])
                        return
                    }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                _ = sample("motion-timeout")
                finish(false, "Sidebar motion did not settle with the requested width/header in \(timeout) seconds")
            }
            func setExpanded(_ expanded: Bool) async {
                if UserDefaults.standard.bool(forKey: "settingsSidebarVisible") != expanded {
                    guard toggle() else { finish(false, "Cannot activate the actual sidebar control") }
                }
                await settle(expanded: expanded)
            }
            await settle(expanded: true)
            let initialValid = sample("initial", expanded: true)
            await capture("expanded")
            guard initialValid else { finish(false, "Initial sidebar/title state incorrect") }
            for cycle in 1...3 {
                guard toggle() else { finish(false, "Cannot collapse sidebar") }
                var previousWidth: CGFloat = 173
                for frame in 1...10 {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    let current = viewportWidth()
                    guard current >= 0 && current <= previousWidth + 1.5 else { finish(false, "Sidebar reversed while collapsing") }
                    previousWidth = current
                    guard sample("collapsing-\(cycle)-\(frame)") else { finish(false, "Native toolbar invariant failed during collapse") }
                }
                if cycle == 1 {
                    // Request a compositor image near the header handoff. Record
                    // before/after marker state so a late image cannot be called
                    // an intermediate frame accidentally.
                    try? await Task.sleep(nanoseconds: 170_000_000)
                    await capture("transition")
                }
                await settle(expanded: false)
                guard sample("collapsed-\(cycle)", expanded: false) else { finish(false, "Collapsed tabs state incorrect") }
                if cycle == 1 { await capture("collapsed") }
                guard toggle() else { finish(false, "Cannot expand sidebar") }
                previousWidth = 0
                for frame in 1...10 {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    let current = viewportWidth()
                    guard current >= previousWidth - 1.5 && current <= 174 else { finish(false, "Sidebar reversed while expanding") }
                    previousWidth = current
                    guard sample("expanding-\(cycle)-\(frame)") else { finish(false, "Native toolbar invariant failed during expansion") }
                }
                await settle(expanded: true)
                guard sample("expanded-\(cycle)", expanded: true) else { finish(false, "Expanded title state incorrect") }
            }
            // Exercise actual NSSegmentedControl actions and then reopen the
            // sidebar, ensuring both navigation forms share one selection.
            for language in ["zh-Hans", "en"] {
                expectedLanguage = language
                UserDefaults.standard.set(language, forKey: "appLanguage")
                NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
                await settle()
                for width in [660.0, 1000.0] {
                    window.setContentSize(NSSize(width: width, height: 620)); await settle()
                    await setExpanded(true)
                    guard sample("\(language)-\(Int(width))-expanded", expanded: true) else { finish(false, "Resized/localized title incorrect") }
                    await setExpanded(false)
                    guard sample("\(language)-\(Int(width))-collapsed", expanded: false) else { finish(false, "Resized/localized tabs truncated") }
                    if width == 660 { await capture(language + "-collapsed-660") }
                }
                for page in ReceiverSettingsPage.allCases.indices {
                    await setExpanded(false)
                    guard let control = tabs(), control.segmentCount == 4 else { finish(false, "Native segmented navigation missing") }
                    control.selectedSegment = page
                    guard control.sendAction(control.action, to: control.target) else { finish(false, "Native tab action was not dispatched") }
                    expectedPage = page; await settle()
                    guard sample("\(language)-page-\(page)-tabs", expanded: false) else { finish(false, "Native tabs did not select expected page") }
                    await setExpanded(true)
                    guard sample("\(language)-page-\(page)-sidebar", expanded: true), sidebarTable()?.selectedRow == page else {
                        finish(false, "Tab selection was not preserved in the native sidebar/title")
                    }
                    await setExpanded(false)
                    guard sample("\(language)-page-\(page)-restored", expanded: false) else { finish(false, "Sidebar selection was not preserved in tabs") }
                }
                await setExpanded(true)
                if language == "en" { await capture("en-expanded") }
            }
            // Keep the selected page across reversals in each motion phase.
            // These are real repeated actions; obsolete phase completions must
            // never replace the latest target/header or duplicate toolbar items.
            for startExpanded in [true, false] {
                for delayMs in [40, 180, 400] {
                    await setExpanded(startExpanded)
                    guard toggle() else { finish(false, "Cannot begin rapid reversal") }
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                    guard sample("rapid-\(startExpanded)-\(delayMs)-outgoing") else { finish(false, "Native toolbar invariant failed during rapid motion") }
                    guard toggle() else { finish(false, "Cannot reverse an in-flight sidebar motion") }
                    await settle(expanded: startExpanded)
                    guard sample("rapid-\(startExpanded)-\(delayMs)-settled", expanded: startExpanded) else {
                        finish(false, "A superseded motion changed the final header/page")
                    }
                    if startExpanded && sidebarTable()?.selectedRow != expectedPage { finish(false, "Selection lost after rapid reversal") }
                }
            }
            await setExpanded(true)
            for press in 0..<5 {
                guard toggle() else { finish(false, "Sidebar control stopped accepting rapid actions") }
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard sample("rapid-burst-\(press)") else { finish(false, "Native toolbar invariant failed during rapid burst") }
            }
            await settle(expanded: false)
            guard sample("rapid-burst-final", expanded: false) else { finish(false, "Rapid burst did not preserve latest target/page") }
            await setExpanded(true)
            guard sample("rapid-restored", expanded: true), sidebarTable()?.selectedRow == expectedPage else {
                finish(false, "Selected page was lost after rapid burst")
            }
            finish(true, "One sidebar control; staged motion settles at the latest target; four-page selection survives reversals, both languages and window widths")
        }
    }
}
