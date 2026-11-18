import AppKit
import ApplicationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import Darwin
import QuartzCore
import SwiftUI

@main struct SettingsDetailsSmoke: App {
    @NSApplicationDelegateAdaptor(DetailsSmokeDelegate.self) private var delegate
    @StateObject private var driver = DetailsSmokeDriver()

    init() {
        precondition(Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.settings-details-check")
        UserDefaults.standard.setVolatileDomain([
            "uiFontFamily": "", "uiFontWeight": 400, "appLanguage": "en",
            "ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false
        ], forName: UserDefaults.argumentDomain)
    }
    var body: some Scene {
        Window("Settings Details Check", id: "settings-details-check") {
            HStack(spacing: 0) {
                Text("Sidebar stays sharp").frame(width: 160).frame(maxHeight: .infinity)
                    .background(DetailsSidebarMarker())
                Form {
                    FontSettingsSection()
                    Section("Controlled scrolling content") {
                        ForEach(0..<24) { index in
                            Text("High contrast content row \(index)").font(.system(size: 18, weight: .semibold))
                        }
                    }
                }.formStyle(.grouped).appTypography().id(driver.scrollPage)
                    .clipped()
                    .overlay { SettingsHeaderBackdrop(checkReduceTransparency: driver.reduceTransparency, checkReduceMotion: driver.reduceMotion).allowsHitTesting(false).accessibilityHidden(true) }
            }
                .background(DetailsWindowProbe(driver: driver).frame(width: 0, height: 0))
                .toolbar { ToolbarItem(placement: .navigation) { Text("Appearance") } }
                .toolbarBackground(.hidden, for: .windowToolbar)
        }.defaultSize(width: 660, height: 500)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
    }
}

private final class DetailsSmokeDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
            FileHandle.standardError.write(Data("FAIL: settings detail check timed out\n".utf8)); exit(1)
        }
    }
}

@MainActor private final class DetailsSmokeDriver: ObservableObject {
    @Published var reduceTransparency = false
    @Published var reduceMotion = false
    @Published var scrollPage = 0
    private var started = false
    private var attachedSheets: [NSWindow] = []
    private var originalFrontmost: pid_t?

    func start(_ window: NSWindow) {
        guard !started else { return }; started = true
        originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        window.alphaValue = 0; window.orderBack(nil)
        SettingsDetailPanelCheckEvents.windowAttached = { [weak self] sheet in
            // Before the native sheet's first draw: never show test windows.
            sheet.alphaValue = 0
            self?.attachedSheets.append(sheet)
        }
        Task { @MainActor in
            await pause(0.5)
            var ownWindows: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &ownWindows)
            let before = fontPreferences()
            guard window.attachedSheet == nil else { fail("Sheet must be closed by default", window) }
            await verifyHeaderScroll(window)
            guard press("settings.font.details", in: window) else { fail("Font row was not actionable", window) }
            guard await waitForSheet(window, presented: true), let sheet = window.attachedSheet else { fail("Font row did not open a native sheet", window) }
            verifySheet(sheet, parent: window)
            guard press("settings.details.close", in: sheet) else { fail("Close action missing", window) }
            guard await waitForSheet(window, presented: false), window.isVisible else { fail("Close dismissed the parent or kept its sheet", window) }

            guard press("settings.font.details", in: window), await waitForSheet(window, presented: true), let escapeSheet = window.attachedSheet else { fail("Could not reopen detail sheet", window) }
            postKey("\u{1b}", keyCode: 53, modifiers: [], window: escapeSheet)
            guard await waitForSheet(window, presented: false), window.isVisible else { fail("Escape did not dismiss only the sheet", window) }

            guard press("settings.font.details", in: window), await waitForSheet(window, presented: true), let closeSheet = window.attachedSheet else { fail("Could not reopen sheet for Cmd-W", window) }
            postKey("w", keyCode: 13, modifiers: .command, window: closeSheet)
            guard await waitForSheet(window, presented: false), window.isVisible else { fail("Cmd-W did not dismiss only the sheet", window) }

            reduceTransparency = true
            await pause(0.15)
            verifyHeader(window, reduced: true)
            guard (before as NSDictionary).isEqual(to: fontPreferences()) else { fail("Opening/closing details changed font preferences", window) }
            guard attachedSheets.count >= 3 && attachedSheets.allSatisfy({ $0.alphaValue == 0 }) else { fail("A detail test window was not hidden", window) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost else { fail("Hidden test changed the foreground application", window) }
            print("PASS: actual native Form scroll, no filter at top, scroll-driven pure variable content blur, original filters restored, no material/tint/fallback, sidebar/toolbar/window controls excluded; font-row Close/Escape/Cmd-W and preferences preserved (all windows alpha 0; no screenshots or app activation)")
            SettingsDetailPanelCheckEvents.windowAttached = nil
            window.orderOut(nil); window.close(); exit(0)
        }
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func waitForSheet(_ window: NSWindow, presented: Bool) async -> Bool {
        let until = Date().addingTimeInterval(2)
        repeat {
            if (window.attachedSheet != nil) == presented { await pause(0.05); return true }
            await pause(0.02)
        } while Date() < until
        return false
    }
    private func fontPreferences() -> [String: Any] {
        let stored = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!) ?? [:]
        return stored.filter { ["uiFontFamily", "uiFontWeight"].contains($0.key) }
    }
    private func findView<T: NSView>(_ type: T.Type, in root: NSView?, id: String? = nil) -> T? {
        guard let root else { return nil }
        if let match = root as? T, id == nil || match.identifier?.rawValue == id { return match }
        return root.subviews.compactMap { findView(type, in: $0, id: id) }.first
    }
    private func verifyHeader(_ window: NSWindow, reduced: Bool = false) {
        guard let bridge = findView(SettingsHeaderBackdrop.BackdropView.self, in: window.contentView),
              let scroll = bridge.trackedScrollView, let document = bridge.filteredDocument,
              document === scroll.documentView else { fail("Native Form filter owner missing", window) }
        guard bridge.hitTest(.zero) == nil, bridge.subviews.isEmpty,
              bridge.layer?.backgroundColor == nil else { fail("Header must draw no material, tint, fallback or copied image", window) }
        let effects = document.contentFilters.filter { $0.name == bridge.filterName }
        if reduced || bridge.scrollOffset < 0.01 {
            guard effects.isEmpty, bridge.currentRadius == 0, bridge.bandInDocument.isEmpty else {
                fail("Top position or Reduce Transparency must remove the filter", window)
            }
            return
        }
        guard effects.count == 1, let effect = effects.first,
              let radius = effect.value(forKey: kCIInputRadiusKey) as? NSNumber,
              abs(radius.doubleValue - Double(bridge.currentRadius)) < 0.01,
              effect.value(forKey: "inputMask") is CIImage,
              bridge.currentRadius > 0, bridge.currentRadius <= 24.01,
              abs(bridge.bandInDocument.height - min(56, scroll.contentView.bounds.height)) < 0.01 else {
            fail("Native variable blur radius, mask or top-band dimensions are wrong", window)
        }
        let frame = document.convert(bridge.bandInDocument, to: nil)
        let scope = bridge.convert(bridge.bounds, to: nil)
        guard let sidebar = findView(NSView.self, in: window.contentView, id: "settings.check.sidebar") else { fail("Sidebar scope marker missing", window) }
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: nil)
        let clipVisible = scroll.contentView.convert(scroll.contentView.visibleRect, to: nil)
        let documentVisible = document.convert(document.visibleRect, to: nil)
        guard frame.maxY <= window.contentLayoutRect.maxY + 1,
              clipVisible.maxY <= window.contentLayoutRect.maxY + 1,
              documentVisible.maxY <= window.contentLayoutRect.maxY + 1,
              frame.minX >= sidebarFrame.maxX - 1,
              frame.maxX <= scope.maxX + 1 else { fail("Filtered content escaped the detail clipping boundary", window) }
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind), let parent = button.superview {
                let buttonFrame = parent.convert(button.frame, to: nil)
                guard !frame.intersects(buttonFrame), button.alphaValue == 1 else { fail("Filter touches or dims a native window control", window) }
            }
        }
    }
    private func verifyHeaderScroll(_ window: NSWindow) async {
        guard let bridge = findView(SettingsHeaderBackdrop.BackdropView.self, in: window.contentView) else { fail("Blur bridge missing", window) }
        bridge.refreshObservation()
        guard let scroll = bridge.trackedScrollView, let document = scroll.documentView else { fail("Blur did not bind to the actual Form scroll view", window) }
        let original = CIFilter.colorControls()
        original.name = "settings.check.original-filter"
        original.saturation = 1
        document.contentFilters = document.contentFilters + [original]
        let clip = scroll.contentView
        let rect = clip.documentRect
        let top = document.isFlipped ? rect.minY : rect.maxY - clip.bounds.height
        func scrollBy(_ amount: CGFloat) {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top + (document.isFlipped ? amount : -amount)))
            scroll.reflectScrolledClipView(clip)
        }
        scrollBy(0)
        await pause(0.25)
        verifyHeader(window)
        guard bridge.scrollOffset < 1, bridge.revealProgress == 0, bridge.currentRadius == 0 else { fail("Blur must be absent at the document top", window) }
        scrollBy(22)
        await pause(0.25)
        guard bridge.revealProgress > 0.05, bridge.revealProgress < 0.95,
              bridge.currentRadius > 0, bridge.currentRadius < 24 else { fail("Header reveal must increase continuously with scrolling", window) }
        verifyHeader(window)
        scrollBy(90)
        await pause(0.25)
        guard bridge.revealProgress == 1, bridge.currentRadius == 24 else { fail("Scrolling past the header must reveal the native blur", window) }
        verifyHeader(window)
        scrollBy(0)
        await pause(0.25)
        guard bridge.revealProgress == 0, bridge.currentRadius == 0 else { fail("Returning to top must remove the blur", window) }
        reduceMotion = true
        await pause(0.1)
        scrollBy(90)
        await pause(0.03)
        guard bridge.revealProgress == 1, bridge.currentRadius == 24,
              bridge.revealAnimationDuration == 0 else { fail("Reduce Motion must reveal immediately without forced fading", window) }
        scrollBy(0)
        await pause(0.03)
        guard bridge.revealProgress == 0, bridge.currentRadius == 0,
              bridge.revealAnimationDuration == 0 else { fail("Reduce Motion must clear the blur immediately at top", window) }
        reduceMotion = false
        await pause(0.1)
        scrollBy(90)
        await pause(0.25)
        scrollPage += 1
        await pause(0.3)
        guard let currentBridge = findView(SettingsHeaderBackdrop.BackdropView.self, in: window.contentView),
              let replacement = currentBridge.trackedScrollView, replacement !== scroll,
              currentBridge.revealProgress == 0, currentBridge.currentRadius == 0,
              bridge === currentBridge || bridge.trackedScrollView == nil else {
            fail("Changing pages retained the previous Form offset or observer", window)
        }
        guard document.contentFilters.count == 1,
              document.contentFilters.first === original else { fail("Changing pages did not preserve the original content filters", window) }
        verifyHeader(window)
    }
    private func verifySheet(_ sheet: NSWindow, parent: NSWindow) {
        let size = sheet.contentRect(forFrameRect: sheet.frame).size
        guard sheet.alphaValue == 0, size.width >= 518 && size.width <= 522,
              size.height <= 554 && size.height >= 318,
              sheet.toolbar == nil else { fail("Detail sheet dimensions or toolbar inheritance are wrong", parent) }
    }
    private func press(_ identifier: String, in window: NSWindow) -> Bool {
        guard let root = window.contentView else { return false }
        var queue: [Any] = [root], seen = Set<ObjectIdentifier>(), index = 0
        while index < queue.count && index < 2000 {
            let value = queue[index]; index += 1
            let object = value as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let element = value as? NSAccessibilityProtocol {
                if element.accessibilityIdentifier() == identifier { return element.accessibilityPerformPress() }
                queue.append(contentsOf: element.accessibilityChildren() ?? [])
            } else if let object = value as? NSObject {
                // SwiftUI nodes implement documented modern accessibility
                // selectors without declaring the formal ObjC protocol.
                let idSelector = NSSelectorFromString("accessibilityIdentifier")
                let childrenSelector = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: idSelector),
                   object.perform(idSelector)?.takeUnretainedValue() as? String == identifier {
                    let pressSelector = NSSelectorFromString("accessibilityPerformPress")
                    guard object.responds(to: pressSelector) else { return false }
                    typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                    let action = unsafeBitCast(object.method(for: pressSelector), to: Press.self)
                    return action(object, pressSelector)
                }
                if object.responds(to: childrenSelector),
                   let children = object.perform(childrenSelector)?.takeUnretainedValue() as? [Any] {
                    queue.append(contentsOf: children)
                }
            }
            if let view = value as? NSView { queue.append(contentsOf: view.subviews) }
        }
        print("No accessible control found: \(identifier), traversed \(index) nodes")
        return false
    }
    private func postKey(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow) {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
        NSApp.postEvent(event, atStart: false)
    }
    private func fail(_ reason: String, _ window: NSWindow) -> Never {
        FileHandle.standardError.write(Data(("FAIL: " + reason + "\n").utf8))
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil); window.close(); exit(1)
    }
}

private struct DetailsSidebarMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("settings.check.sidebar")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private struct DetailsWindowProbe: NSViewRepresentable {
    let driver: DetailsSmokeDriver
    func makeNSView(context: Context) -> ProbeView { ProbeView(driver: driver) }
    func updateNSView(_ view: ProbeView, context: Context) {}
    final class ProbeView: NSView {
        let driver: DetailsSmokeDriver
        init(driver: DetailsSmokeDriver) { self.driver = driver; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { driver.start(window) }
        }
    }
}
