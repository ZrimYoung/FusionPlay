import AppKit
import SwiftUI

@MainActor private var dockMutations = 0
@MainActor func applyDockVisibility(_ visible: Bool) { dockMutations += 1 }

@main struct AppearanceGroupingSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.finishLaunching()
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor static func check() async throws {
        let suite = "tech.zrim.fusionplay.appearance-group-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "playerShowsTransport")
        defaults.set(true, forKey: "playerShowsProgress")
        defaults.set(NarrowPlayerLayout.original.rawValue, forKey: NarrowPlayerLayout.storageKey)
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var titleChanges = 0
        let host = NSHostingView(rootView: AppearanceSettingsPage(onTitleCorrectionChanged: { titleChanges += 1 })
            .defaultAppStorage(defaults).environment(\.appTypography, AppTypography()))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900),
            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "AppearanceGrouping", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func pause() async throws {
            try? await Task.sleep(nanoseconds: 200_000_000)
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try require(NSApp.activationPolicy() == .prohibited && !NSRunningApplication.current.isActive
                        && NSWorkspace.shared.frontmostApplication?.processIdentifier == originalFrontmost
                        && !window.isVisible && window.alphaValue == 0 && dockMutations == 0,
                        "Silent settings check changed the frontmost app, visibility or entry points")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func switches() -> [NSSwitch] {
            descendants(host).compactMap { $0 as? NSSwitch }.sorted {
                $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
            }
        }
        func choose(_ title: String) throws {
            for control in descendants(host).compactMap({ $0 as? NSSegmentedControl }) {
                if let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == title }) {
                    control.selectedSegment = index
                    try require(control.sendAction(control.action, to: control.target), "Native segmented binding action failed")
                    return
                }
            }
            let labels = descendants(host).compactMap { $0 as? NSSegmentedControl }.flatMap { control in
                (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "nil" }
            }
            throw NSError(domain: "Missing native segment \(title): \(labels)", code: 1)
        }
        func clickSwitch(_ index: Int, expectedCount: Int) throws {
            let controls = switches()
            try require(controls.count == expectedCount, "Unexpected switch count: \(controls.count), expected \(expectedCount)")
            controls[index].performClick(nil)
        }
        try await pause()
        try require(PlayerLayoutFamily.allCases.map(\.transportKey) == ["coverPlayerShowsTransport", "albumPlayerShowsTransport"]
                    && PlayerLayoutFamily.allCases.map(\.progressKey) == ["coverPlayerShowsProgress", "albumPlayerShowsProgress"],
                    "Layout preference keys changed")
        for family in PlayerLayoutFamily.allCases {
            try require(defaults.object(forKey: family.transportKey) == nil && defaults.object(forKey: family.progressKey) == nil,
                        "Reading settings eagerly migrated a layout preference")
        }
        try require(switches().count == 5, "Cover player should expose its two display, two window and one metadata switches")
        try require(switches()[0].state == .off && switches()[1].state == .on, "Initial display switches did not inherit legacy values")
        try clickSwitch(0, expectedCount: 5); try await pause()
        try require(defaults.object(forKey: PlayerLayoutFamily.cover.transportKey) as? Bool == true,
                    "Cover toggle did not save independently")
        try choose("专辑模式"); try await pause()
        try require(defaults.string(forKey: NarrowPlayerLayout.storageKey) == NarrowPlayerLayout.ipadPaged.rawValue
                    && switches().count == 7, "Album settings did not add its two lyric-header options")
        try clickSwitch(0, expectedCount: 7); try await pause()
        try clickSwitch(0, expectedCount: 7); try await pause()
        try clickSwitch(1, expectedCount: 7); try await pause()
        try require(defaults.object(forKey: PlayerLayoutFamily.album.transportKey) as? Bool == false
                    && defaults.object(forKey: PlayerLayoutFamily.album.progressKey) as? Bool == false
                    && defaults.object(forKey: PlayerLayoutFamily.cover.transportKey) as? Bool == true
                    && defaults.object(forKey: PlayerLayoutFamily.cover.progressKey) == nil,
                    "Album toggles overwrote cover preferences or lost an explicit false")
        try require(!defaults.bool(forKey: "playerShowsTransport") && defaults.bool(forKey: "playerShowsProgress"),
                    "Scoped controls modified the legacy shared preferences")
        try choose("封面模式"); try await pause()
        try require(switches().count == 5 && switches()[0].state == .on && switches()[1].state == .on,
                    "Switching modes lost cover values or legacy fallback")
        try choose("歌词"); try await pause()
        try require(switches().count == 3, "Lyrics category should isolate shortcut, title correction and stagger switches")
        try clickSwitch(1, expectedCount: 3); try await pause()
        try require(titleChanges == 1, "Title-correction callback was lost")
        try choose("通用"); try await pause()
        try require(switches().count == 2, "General category should isolate Dock and menu entry switches")
        print("PASS: unshown alpha-zero native appearance categories, actual segmented/toggle bindings, independent optional preferences, legacy fallback without migration, explicit false and title callback; frontmost app unchanged")
    }
}
