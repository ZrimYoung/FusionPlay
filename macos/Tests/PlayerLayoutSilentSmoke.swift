import AppKit
import SwiftUI

@main struct PlayerLayoutSilentSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor private static func check() async throws {
        let defaults = UserDefaults.standard
        guard let domain = Bundle.main.bundleIdentifier, domain == "tech.zrim.fusionplay.narrow-ui-check" else {
            throw NSError(domain: "Unexpected test bundle", code: 1)
        }
        defaults.removePersistentDomain(forName: domain)
        defaults.register(defaults: ["appLanguage": "en", "playerShowsTransport": false, "playerShowsProgress": true,
            "playerLyricsDisplayMode": "never", "playerWindowPinned": false, "playerControlsAlwaysVisible": true,
            "playerShowsLyricsButton": true, "lyricsPageShowsArtwork": true, "lyricsPageShowsTrackInfo": true,
            NarrowPlayerLayout.storageKey: NarrowPlayerLayout.squarePaged.rawValue])
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FUSIONPLAY_NARROW_CHECK_ROOT"]!)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FUSIONPLAY_NARROW_CHECK_OUTPUT"]!)
        let state = Snapshot(phase: .playing, title: "A long synthetic song title for silent layout checks",
            artist: "A synthetic artist", album: "A synthetic album", trackId: "silent-layout", artworkUrl: "",
            lyricsText: "[00:00]A quiet morning\n[00:06]A new line to read\n[00:12]Another line",
            durationMs: 180_000, positionMs: 8_000, controlsAvailable: true, volume: 50,
            message: "", address: "", output: "", queueMs: 0, outputLatencyMs: 0, scheduleErrorMs: 0,
            underruns: 0, droppedFrames: 0, resyncs: 0)
        let image = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSGradient(starting: .systemIndigo, ending: .systemPink)?.draw(in: rect, angle: 45); return true
        }
        let model = ReceiverModel.preview(state, artwork: image, root: root)
        let host = NSHostingView(rootView: PlayerView(model: model).appTypography())
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func require(_ value: Bool, _ text: String) throws {
            if !value { throw NSError(domain: "SilentPlayerLayout", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        }
        func settle() async throws {
            try? await Task.sleep(nanoseconds: 450_000_000)
            host.layoutSubtreeIfNeeded()
            try require(window.alphaValue == 0 && !window.isVisible && !window.isKeyWindow
                && NSApp.activationPolicy() == .prohibited
                && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
                "Silent check displayed a window or changed foreground focus")
        }
        func snapshot() throws -> PlayerAppearanceCheckSnapshot {
            guard let value = PlayerAppearanceCheckState.latest else { throw NSError(domain: "No live view state", code: 1) }
            return value
        }
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NSError(domain: "No offscreen bitmap", code: 1)
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
        }
        try await settle()
        var value = try snapshot()
        try require(value.cover && !value.transport && value.progress, "Legacy shared preferences were not preserved")
        try require(!value.lyricsArtwork && !value.lyricsInfo, "Album-only lyric header leaked into cover mode")
        defaults.set(true, forKey: "coverPlayerShowsTransport"); defaults.set(false, forKey: "coverPlayerShowsProgress")
        try await settle(); value = try snapshot()
        try require(value.cover && value.transport && !value.progress, "Cover-specific display did not update live")
        defaults.set(NarrowPlayerLayout.ipadPaged.rawValue, forKey: NarrowPlayerLayout.storageKey)
        try await settle(); value = try snapshot()
        try require(!value.cover && !value.transport && value.progress, "Album mode inherited cover overrides")
        try require(value.lyricsArtwork && value.lyricsInfo, "Album lyric header preferences disappeared")
        defaults.set(false, forKey: "albumPlayerShowsProgress"); defaults.set(true, forKey: "albumPlayerShowsTransport")
        try await settle()
        defaults.set(NarrowPlayerLayout.squarePaged.rawValue, forKey: NarrowPlayerLayout.storageKey)
        try await settle(); value = try snapshot()
        try require(value.cover && value.transport && !value.progress, "Cover preference was lost on switching back")
        defaults.set(NarrowPlayerLayout.ipadPaged.rawValue, forKey: NarrowPlayerLayout.storageKey)
        try await settle(); value = try snapshot()
        try require(!value.cover && value.transport && !value.progress, "Album preference was lost on switching back")
        try require(defaults.object(forKey: "playerShowsTransport") as? Bool == false
            && defaults.object(forKey: "playerShowsProgress") as? Bool == true, "Legacy preferences were overwritten")
        defaults.set(true, forKey: "albumPlayerShowsProgress")
        for size in [NSSize(width: 284, height: 634), NSSize(width: 547, height: 634), NSSize(width: 420, height: 870)] {
            window.setContentSize(size); try await settle()
            try capture("silent-album-\(Int(size.width))-\(Int(size.height))")
        }
        // Confirm saved per-layout values survive a fresh view instance.
        window.contentView = nil
        let reopened = NSHostingView(rootView: PlayerView(model: model).appTypography())
        window.contentView = reopened; try await settle()
        value = try snapshot()
        try require(!value.cover && value.transport && value.progress, "Fresh view did not restore album preferences")
        print("PASS: fully offscreen PlayerView, live per-layout controls/progress, legacy fallback, switching and restoration, album-only header; no window ordering, receiver, screen capture or focus changes")
    }
}
