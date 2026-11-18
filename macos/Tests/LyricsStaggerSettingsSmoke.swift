import AppKit
import ApplicationServices
import Darwin
import SwiftUI

@main struct LyricsStaggerSettingsSmoke: App {
    @NSApplicationDelegateAdaptor(StaggerSettingsDelegate.self) private var delegate
    @StateObject private var driver = StaggerSettingsDriver()
    init() {
        precondition(Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.stagger-settings-check")
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: LyricsStaggerTiming.enabledStorageKey)
        defaults.removeObject(forKey: LyricsStaggerTiming.millisecondsStorageKey)
        defaults.removeObject(forKey: LyricsTypography.storageKey)
        defaults.removeObject(forKey: LyricsStaggerTiming.moveStorageKey)
        defaults.register(defaults: [LyricsStaggerTiming.enabledStorageKey: LyricsStaggerTiming.defaultEnabled,
            LyricsStaggerTiming.millisecondsStorageKey: LyricsStaggerTiming.defaultMilliseconds,
            LyricsTypography.storageKey: LyricsTypography.defaultScalePercent,
            LyricsStaggerTiming.moveStorageKey: LyricsStaggerTiming.defaultMoveMilliseconds])
        defaults.setVolatileDomain(["appLanguage": "en", "uiFontFamily": "", "uiFontWeight": 400,
            "ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false], forName: UserDefaults.argumentDomain)
    }
    var body: some Scene {
        Window("Lyrics Stagger Settings Check", id: "stagger-settings") {
            Form { LyricsStaggerSettingsSection() }.formStyle(.grouped).appTypography()
                .background(StaggerSettingsWindowProbe(driver: driver).frame(width: 0, height: 0))
        }.defaultSize(width: 540, height: 570).windowStyle(.hiddenTitleBar)
    }
}

private final class StaggerSettingsDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            FileHandle.standardError.write(Data("FAIL: stagger settings check timed out\n".utf8)); exit(1)
        }
    }
}

@MainActor private final class StaggerSettingsDriver: ObservableObject {
    private var started = false
    func start(_ window: NSWindow) {
        guard !started else { return }; started = true
        window.alphaValue = 0; window.orderBack(nil)
        // SwiftUI may restore this isolated helper's older 360pt geometry.
        window.setContentSize(NSSize(width: 540, height: 570))
        Task { @MainActor in
            await pause(0.8)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // A public self-application query initializes SwiftUI's lazy AX
            // bridge without touching another application or asking permission.
            var ownWindows: CFTypeRef?
            let axStatus = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &ownWindows)
            guard axStatus == .success else { fail("Self AX bridge initialization failed", window) }
            await pause(0.08)
            let defaults = UserDefaults.standard
            guard LyricsTypography.clampScalePercent(-1) == LyricsTypography.scaleRange.lowerBound,
                  LyricsTypography.clampScalePercent(500) == LyricsTypography.scaleRange.upperBound,
                  LyricsTypography.scale(percent: 100) == 1,
                  abs(LyricsTypography.scale(percent: 165) - 1.65) < 0.000_001,
                  defaults.bool(forKey: LyricsStaggerTiming.enabledStorageKey),
                  defaults.integer(forKey: LyricsStaggerTiming.millisecondsStorageKey) == LyricsStaggerTiming.defaultMilliseconds,
                  defaults.integer(forKey: LyricsTypography.storageKey) == LyricsTypography.defaultScalePercent,
                  defaults.integer(forKey: LyricsStaggerTiming.moveStorageKey) == LyricsStaggerTiming.defaultMoveMilliseconds,
                  matchesSlider("settings.lyrics.font.scale", value: 100, range: LyricsTypography.scaleRange, window: window),
                  matchesSlider("settings.lyrics.move.duration", value: 420, range: LyricsStaggerTiming.moveMillisecondsRange, window: window),
                  matchesSlider("settings.lyrics.stagger.span", value: 140, range: LyricsStaggerTiming.millisecondsRange, window: window)
                  else { fail("Default typography/motion preferences or public slider ranges are wrong", window) }
            setSlider(167, identifier: "settings.lyrics.font.scale", window: window)
            await pause(0.08)
            guard defaults.integer(forKey: LyricsTypography.storageKey) == 165,
                  matchesSlider("settings.lyrics.font.scale", value: 165, range: LyricsTypography.scaleRange, window: window),
                  defaults.integer(forKey: LyricsStaggerTiming.moveStorageKey) == 420,
                  defaults.integer(forKey: LyricsStaggerTiming.millisecondsStorageKey) == 140,
                  defaults.bool(forKey: LyricsStaggerTiming.enabledStorageKey)
                  else { fail("Font size did not save a 5% step independently", window) }
            setSlider(837, identifier: "settings.lyrics.move.duration", window: window)
            await pause(0.08)
            guard defaults.integer(forKey: LyricsStaggerTiming.moveStorageKey) == 840,
                  matchesSlider("settings.lyrics.move.duration", value: 840, range: LyricsStaggerTiming.moveMillisecondsRange, window: window),
                  defaults.integer(forKey: LyricsTypography.storageKey) == 165,
                  defaults.integer(forKey: LyricsStaggerTiming.millisecondsStorageKey) == 140
                  else { fail("Line movement did not save a 10ms step independently", window) }
            setSlider(197, identifier: "settings.lyrics.stagger.span", window: window)
            await pause(0.08)
            guard defaults.integer(forKey: LyricsStaggerTiming.millisecondsStorageKey) == 200,
                  matchesSlider("settings.lyrics.stagger.span", value: 200, range: LyricsStaggerTiming.millisecondsRange, window: window)
                  else { fail("Stagger span did not save a 10ms step immediately", window) }
            guard action("settings.lyrics.stagger.span", selector: "accessibilityPerformIncrement", window: window) else {
                fail("Slider accessibility increment is unavailable", window)
            }
            await pause(0.06)
            guard defaults.integer(forKey: LyricsStaggerTiming.millisecondsStorageKey) == 210 else { fail("Accessibility increment did not use 10ms", window) }
            // SwiftUI's checkbox can return false after successfully switching
            // off. Assert the observable preference/control state instead.
            _ = action("settings.lyrics.stagger.enabled", selector: "accessibilityPerformPress", window: window)
            await pause(0.35)
            guard !defaults.bool(forKey: LyricsStaggerTiming.enabledStorageKey),
                  findAccessible("settings.lyrics.stagger.span", window: window) == nil,
                  defaults.integer(forKey: LyricsStaggerTiming.millisecondsStorageKey) == 210,
                  matchesSlider("settings.lyrics.font.scale", value: 165, range: LyricsTypography.scaleRange, window: window),
                  matchesSlider("settings.lyrics.move.duration", value: 840, range: LyricsStaggerTiming.moveMillisecondsRange, window: window)
                  else { fail("Disabling stagger changed font/movement controls or lost span", window) }
            _ = action("settings.lyrics.stagger.enabled", selector: "accessibilityPerformPress", window: window)
            await pause(0.35)
            guard defaults.bool(forKey: LyricsStaggerTiming.enabledStorageKey),
                  matchesSlider("settings.lyrics.stagger.span", value: 210, range: LyricsStaggerTiming.millisecondsRange, window: window),
                  defaults.integer(forKey: LyricsTypography.storageKey) == 165,
                  defaults.integer(forKey: LyricsStaggerTiming.moveStorageKey) == 840,
                  window.alphaValue == 0 else { fail("Re-enabling did not preserve independent lyric preferences", window) }
            defaults.removeObject(forKey: LyricsStaggerTiming.enabledStorageKey)
            defaults.removeObject(forKey: LyricsStaggerTiming.millisecondsStorageKey)
            defaults.removeObject(forKey: LyricsTypography.storageKey)
            defaults.removeObject(forKey: LyricsStaggerTiming.moveStorageKey)
            print("PASS: lyric font 100%/75...200 with 167→165; line move 420ms/100...1500 with 837→840; stagger default140ms/range \(LyricsStaggerTiming.millisecondsRange), immediate 10ms steps and hide/show preservation; all preferences isolated, window hidden")
            window.orderOut(nil); window.close(); exit(0)
        }
    }
    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    private func matchesSlider(_ identifier: String, value: Int, range: ClosedRange<Int>, window: NSWindow) -> Bool {
        guard let slider = findAccessible(identifier, window: window) else { return false }
        return number(slider, "accessibilityValue") == Double(value)
            && number(slider, "accessibilityMinValue") == Double(range.lowerBound)
            && number(slider, "accessibilityMaxValue") == Double(range.upperBound)
    }
    private func setSlider(_ value: Int, identifier: String, window: NSWindow) {
        let setter = NSSelectorFromString("setAccessibilityValue:")
        guard let slider = findAccessible(identifier, window: window), slider.responds(to: setter) else {
            fail("Slider value setter unavailable: " + identifier, window)
        }
        typealias SetValue = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let setValue = unsafeBitCast(slider.method(for: setter), to: SetValue.self)
        setValue(slider, setter, NSNumber(value: value))
    }
    private func number(_ object: NSObject, _ name: String) -> Double? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return (object.perform(selector)?.takeUnretainedValue() as? NSNumber)?.doubleValue
    }
    private func action(_ identifier: String, selector name: String, window: NSWindow) -> Bool {
        let selector = NSSelectorFromString(name)
        guard let object = findAccessible(identifier, window: window) else { return false }
        var queue: [NSObject] = [object], seen = Set<ObjectIdentifier>(), index = 0
        while index < queue.count && index < 100 {
            let item = queue[index]; index += 1
            guard seen.insert(ObjectIdentifier(item)).inserted else { continue }
            if item.responds(to: selector), invoke(item, selector) { return true }
            let childSelector = NSSelectorFromString("accessibilityChildren")
            if item.responds(to: childSelector), let children = item.perform(childSelector)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: children)
            }
        }
        return false
    }
    private func findAccessible(_ identifier: String, window: NSWindow) -> NSObject? {
        guard let root = window.contentView else { return nil }
        var queue: [Any] = [window, root], seen = Set<ObjectIdentifier>(), index = 0
        while index < queue.count && index < 2000 {
            let value = queue[index]; index += 1
            let object = value as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let accessible = value as? NSAccessibilityProtocol {
                if accessible.accessibilityIdentifier() == identifier { return value as? NSObject }
                queue.append(contentsOf: accessible.accessibilityChildren() ?? [])
            } else if let object = value as? NSObject {
                let idSelector = NSSelectorFromString("accessibilityIdentifier")
                let childSelector = NSSelectorFromString("accessibilityChildren")
                if object.responds(to: idSelector), object.perform(idSelector)?.takeUnretainedValue() as? String == identifier { return object }
                if object.responds(to: childSelector), let children = object.perform(childSelector)?.takeUnretainedValue() as? [Any] {
                    queue.append(contentsOf: children)
                }
            }
            if let view = value as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return nil
    }
    private func invoke(_ object: NSObject, _ selector: Selector) -> Bool {
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(object.method(for: selector), to: Action.self)
        return action(object, selector)
    }
    private func fail(_ reason: String, _ window: NSWindow) -> Never {
        FileHandle.standardError.write(Data(("FAIL: " + reason + "\n").utf8))
        window.orderOut(nil); window.close(); exit(1)
    }
}

private struct StaggerSettingsWindowProbe: NSViewRepresentable {
    let driver: StaggerSettingsDriver
    func makeNSView(context: Context) -> ProbeView { ProbeView(driver: driver) }
    func updateNSView(_ view: ProbeView, context: Context) {}
    final class ProbeView: NSView {
        let driver: StaggerSettingsDriver
        init(driver: StaggerSettingsDriver) { self.driver = driver; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { driver.start(window) } }
    }
}
