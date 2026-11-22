import AppKit
import Combine
import SwiftUI

@MainActor private final class ResponsiveTestClock { var time: TimeInterval = 10_000 }

@main struct PlayerResponsiveMotionSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("FAIL: responsive motion test timed out\n".utf8)); exit(124)
        }
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }

    @MainActor private static func check() async throws {
        let domain = "tech.zrim.fusionplay.responsive-motion-check"
        guard Bundle.main.bundleIdentifier == domain,
              let rootPath = ProcessInfo.processInfo.environment["FUSIONPLAY_RESPONSIVE_CHECK_ROOT"],
              let outputPath = ProcessInfo.processInfo.environment["FUSIONPLAY_RESPONSIVE_CHECK_OUTPUT"] else {
            throw failure("Unexpected isolated test environment")
        }
        try checkMarkerOwnership()
        try checkPublicationFrequency()
        let continuity = try checkDeterministicDriver()
        try await checkAutomaticTimer()
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = URL(fileURLWithPath: rootPath), output = URL(fileURLWithPath: outputPath)
        let state = Snapshot(phase: .playing, title: "MOTION TEST TITLE", artist: "SYNTHETIC ARTIST", album: "SYNTHETIC ALBUM",
            trackId: "responsive-fixture", artworkUrl: "", lyricsText: "[00:00]First synthetic line\n[00:06]Current synthetic line\n[00:12]Next synthetic line",
            durationMs: 180_000, positionMs: 90_000, controlsAvailable: true, volume: 50,
            message: "", address: "", output: "", queueMs: 0, outputLatencyMs: 0, scheduleErrorMs: 0,
            underruns: 0, droppedFrames: 0, resyncs: 0)
        let artwork = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSColor.black.setFill(); rect.fill()
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
            NSRect(x: 51.2, y: 332.8, width: 128, height: 128).fill()
            return true
        }
        let model = ReceiverModel.preview(state, artwork: artwork, root: root)
        var cases: [[String: Any]] = []
        for layout in [NarrowPlayerLayout.squarePaged, .ipadPaged] {
            for lyrics in [false, true] {
                for animationsDisabled in [false, true] {
                    defaults.set(layout.rawValue, forKey: NarrowPlayerLayout.storageKey)
                    defaults.set(lyrics ? LyricsDisplayMode.automatic.rawValue : LyricsDisplayMode.never.rawValue, forKey: LyricsDisplayMode.storageKey)
                    for key in ["playerShowsTransport", "playerShowsProgress", "coverPlayerShowsTransport", "coverPlayerShowsProgress",
                                "albumPlayerShowsTransport", "albumPlayerShowsProgress", "playerControlsAlwaysVisible"] { defaults.set(true, forKey: key) }
                    defaults.set("en", forKey: "appLanguage")
                    defaults.set("custom", forKey: "playerProgressColorMode")
                    defaults.set("#00FF00", forKey: "playerProgressCustomHex")
                    defaults.set(false, forKey: "playerWindowPinned")
                    defaults.set(false, forKey: "playerShowsPinButton")
                    defaults.set(false, forKey: "wrapPlayerMetadata")
                    defaults.set(false, forKey: "coverLyricsExpandedByDragging")
                    let label = "\(layout.rawValue)-lyrics-\(lyrics)-disabled-\(animationsDisabled)"
                    let clock = ResponsiveTestClock()
                    let motion = PlayerResponsiveMotionDriver(animationsEnabled: !animationsDisabled,
                        automaticallyTicks: false, now: { clock.time })
                    let appearances = PlayerCoverLifecycleCheck.appearances
                    let host = NSHostingView(rootView: PlayerView(model: model, responsiveMotion: motion).appTypography())
                    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                        styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
                    defer { window.contentView = nil; window.close() }
                    var samples: [[String: Any]] = []
                    var playbackScroll: NSScrollView?
                    var lyricScroll: NSScrollView?
                    @MainActor func render(_ phase: String, elapsed: Double = 0, save: Bool = false) throws -> [String: Any] {
                        try require(window.alphaValue == 0 && !window.isVisible && !window.isKeyWindow
                            && NSApp.activationPolicy() == .prohibited
                            && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "A check displayed/activated its window")
                        host.needsLayout = true; host.layoutSubtreeIfNeeded()
                        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("No native offscreen bitmap") }
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let markers = markerBounds(bitmap, size: host.bounds.size)
                        var row: [String: Any] = ["phase": phase, "elapsed": elapsed,
                            "width": host.bounds.width, "height": host.bounds.height,
                            "artworkMarker": markers.red.map(rectArray) as Any? ?? NSNull(),
                            "progressMarker": markers.green.map(rectArray) as Any? ?? NSNull(),
                            "moving": motion.isAnimating, "timer": motion.hasScheduledTimer]
                        if let pose = motion.pose {
                            row["artworkFrame"] = rectArray(pose[.artwork].frame)
                            row["artworkOpacity"] = pose[.artwork].opacity
                        }
                        row["keyCompact"] = motion.key?.compact as Any? ?? NSNull()
                        if phase == "wide-initial" {
                            print("INITIAL", String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
                        }
                        samples.append(row)
                        if save { try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("canvas-" + label + "-" + phase + ".png")) }
                        return row
                    }
                    @MainActor func verifyNativeBinding(expectVisibleLyrics: Bool) throws -> NSScrollView? {
                        let nodes = descendants(host)
                        let marked = nodes.compactMap { $0 as? NSScrollView }.filter { $0.identifier == PlayerPlaybackScrollIdentity.scrollIdentifier }
                        try require(marked.count == 1, "Persistent playback native identity was not unique: \(label)")
                        if let playbackScroll { try require(playbackScroll === marked[0], "Playback scroll was recreated") }
                        else { playbackScroll = marked[0] }
                        var bound: [NSScrollView] = []
                        for row in nodes.compactMap({ $0 as? LyricsRowGeometryCheckView }) {
                            if let scroll = row.anchor?.boundScrollForCheck {
                                try require(scroll !== marked[0] && scroll.identifier != PlayerPlaybackScrollIdentity.scrollIdentifier,
                                            "Lyrics anchor attached to playback scroll")
                                try require(row.enclosingScrollView === scroll, "Lyrics anchor attached to a neighbouring scroll")
                                bound.append(scroll)
                            }
                        }
                        let unique = Set(bound.map(ObjectIdentifier.init))
                        try require(unique.count <= 1, "One lyrics subtree bound to multiple native viewports")
                        if expectVisibleLyrics {
                            try require(unique.count == 1, "Visible lyrics never attached their actual native viewport")
                            if let lyricScroll { try require(bound[0] === lyricScroll, "Lyrics native viewport was recreated") }
                            else { lyricScroll = bound[0] }
                        }
                        return bound.first
                    }
                    @MainActor func finish(_ phase: String, save: Bool = true) async throws -> [String: Any] {
                        clock.time += 2; motion.advance(to: clock.time)
                        try await Task.sleep(for: .milliseconds(40))
                        let row = try render(phase, save: save)
                        try require(!motion.isAnimating && !motion.hasScheduledTimer, "Settled canvas retained a timer/motion")
                        guard let red = row["artworkMarker"] as? [Double] else { throw failure("Artwork disappeared: \(label)/\(phase)") }
                        try require(red[2] > 12 && red[3] > 12 && (0.8...1.25).contains(red[2] / red[3]), "Artwork marker cropped/distorted")
                        try require(row["progressMarker"] is [Double], "Progress disappeared: \(label)/\(phase)")
                        _ = try verifyNativeBinding(expectVisibleLyrics: lyrics && host.bounds.width >= 600)
                        try require(PlayerCoverLifecycleCheck.appearances == appearances + 1, "Main cover was recreated across geometry change")
                        return row
                    }
                    @MainActor func resize(_ size: NSSize) async throws {
                        window.setContentSize(size)
                        for _ in 0..<30 {
                            host.needsLayout = true; host.layoutSubtreeIfNeeded()
                            if motion.key?.compact == (size.width < 600) { return }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        throw failure("Canvas did not accept new geometry")
                    }
                    @MainActor func crossing(_ size: NSSize, from first: [String: Any], phase: String) async throws -> (last: [String: Any], count: Int) {
                        clock.time += 0.01
                        try await resize(size)
                        let start = clock.time
                        var frames: [[String: Any]] = []
                        for (index, delta) in [0.06, 0.12, 0.20, 0.35].enumerated() {
                            clock.time = start + delta; motion.advance(to: clock.time)
                            try await Task.sleep(for: .milliseconds(25))
                            frames.append(try render(phase + "-\(index)", elapsed: delta, save: !animationsDisabled && index < 2))
                        }
                        let last = try await finish(phase + "-final")
                        let middle = frames.filter { between($0, from: first, to: last) }
                        if animationsDisabled {
                            try require(frames.allSatisfy { close($0["artworkMarker"] as? [Double], last["artworkMarker"] as? [Double], tolerance: 4) },
                                        "Disabled driver still animated geometry")
                        } else {
                            try require(middle.count >= 2, "No two actual bitmap geometry intermediates: \(label)/\(phase)")
                            let distinct = Set(middle.compactMap { ($0["artworkMarker"] as? [Double]).map { $0.map { Int($0.rounded()) }.description } })
                            try require(distinct.count >= 2, "Bitmap changed opacity only, without distinct intermediate geometry")
                            let modelMiddle = frames.filter { !close($0["artworkFrame"] as? [Double], first["artworkFrame"] as? [Double], tolerance: 0.5)
                                && !close($0["artworkFrame"] as? [Double], last["artworkFrame"] as? [Double], tolerance: 0.5) }
                            try require(modelMiddle.count >= 2, "Actual canvas model did not advance its rectangles")
                        }
                        return (last, middle.count)
                    }
                    _ = try render("boot")
                    try await Task.sleep(for: .milliseconds(180))
                    let wide = try await finish("wide-initial")
                    let narrowSize = NSSize(width: 520, height: layout.isCover ? 520 : 720)
                    let narrow = try await crossing(narrowSize, from: wide, phase: "to-narrow")
                    let returned = try await crossing(NSSize(width: 760, height: 720), from: narrow.last, phase: "to-wide")
                    try require(close(wide["artworkMarker"] as? [Double], returned.last["artworkMarker"] as? [Double], tolerance: 4), "Full roundtrip missed wide endpoint")
                    if lyrics, let scroll = try verifyNativeBinding(expectVisibleLyrics: true) {
                        let position = scroll.contentView.bounds.origin
                        scroll.contentView.scroll(to: NSPoint(x: position.x, y: position.y + 24)); scroll.reflectScrolledClipView(scroll.contentView)
                        try await Task.sleep(for: .milliseconds(80))
                        try require(!motion.isAnimating && !motion.hasScheduledTimer, "Static lyric scrolling restarted canvas animation")
                    }
                    // Reverse twice at the exact current logical time. Root must
                    // retain position, not start a new interpolation from an endpoint.
                    try await resize(narrowSize)
                    clock.time += 0.12; motion.advance(to: clock.time)
                    try await Task.sleep(for: .milliseconds(20))
                    _ = try render("rapid-first")
                    let firstTurn = motion.pose!
                    try await resize(NSSize(width: 760, height: 720))
                    if !animationsDisabled { try require(poseDistance(firstTurn, motion.pose!) < 0.00001, "First reverse jumped current geometry") }
                    clock.time += 0.025; motion.advance(to: clock.time)
                    let secondTurn = motion.pose!
                    try await resize(narrowSize)
                    if !animationsDisabled { try require(poseDistance(secondTurn, motion.pose!) < 0.00001, "Second reverse jumped current geometry") }
                    let reversed = try await finish("rapid-narrow-final")
                    try require(close(narrow.last["artworkMarker"] as? [Double], reversed["artworkMarker"] as? [Double], tolerance: 4), "Rapid reversal missed final target")
                    if layout == .ipadPaged && lyrics {
                        guard let coordinator = host.gestureRecognizers.compactMap({ $0.target as? NarrowPlayerHorizontalScroll.Coordinator }).first else {
                            throw failure("No production paging coordinator")
                        }
                        coordinator.requestPage(.lyrics)
                        for _ in 0..<30 {
                            host.layoutSubtreeIfNeeded()
                            if motion.key?.page == .lyrics { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        clock.time += 2; motion.advance(to: clock.time)
                        try await Task.sleep(for: .milliseconds(80)); _ = try render("lyrics-page", save: true)
                        _ = try verifyNativeBinding(expectVisibleLyrics: true)
                        try require(!motion.isAnimating && !motion.hasScheduledTimer, "Lyrics paging did not settle")
                        coordinator.requestPage(.playback)
                        for _ in 0..<30 {
                            host.layoutSubtreeIfNeeded()
                            if motion.key?.page == .playback { break }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        let pageReturn = try await finish("playback-page-return")
                        try require(close(narrow.last["artworkMarker"] as? [Double], pageReturn["artworkMarker"] as? [Double], tolerance: 4),
                                    "Paging back did not preserve playback canvas")
                    }
                    cases.append(["layout": layout.rawValue, "lyrics": lyrics, "animationsDisabled": animationsDisabled,
                        "layoutPassed": true, "geometryAnimationPassed": true,
                        "toNarrowBitmapIntermediates": narrow.count, "toWideBitmapIntermediates": returned.count,
                        "singleCoverAppearance": true, "uniqueCorrectLyricBinding": true, "idleTimerStopped": true, "samples": samples])
                    print("PASS: \(label), actual bitmap intermediates \(narrow.count)/\(returned.count), reversal/lifecycle/native-binding/idle")
                    window.contentView = nil; window.close(); motion.stop()
                }
            }
        }
        let report: [String: Any] = ["layoutPassed": true, "explicitGeometryAnimationVerified": true,
            "systemReduceMotionBranchVerified": false, "controlledClock": true,
            "automaticCommonTimerVerified": true, "eventTrackingTimerVerified": true, "positionAndVelocityContinuity": continuity,
            "cases": cases, "receiverStarted": false, "realPreferencesChanged": false,
            "windowOrdered": false, "screenCaptured": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("responsive-motion.json"))
        print("PASS: actual PlayerView geometry/bitmap animation, nonlinear motion, rapid reversal, native ownership, lifecycle and idle timers; fully offscreen")
    }

    @MainActor private static func checkPublicationFrequency() throws {
        let clock = ResponsiveTestClock()
        let driver = PlayerResponsiveMotionDriver(automaticallyTicks: false, now: { clock.time })
        var notifications = 0
        let observation = driver.objectWillChange.sink { notifications += 1 }
        defer { observation.cancel() }
        let a = PlayerCanvasPose(nodes: [.artwork: PlayerCanvasNode(frame: CGRect(x: 20, y: 30, width: 100, height: 100))])
        let b = PlayerCanvasPose(nodes: [.artwork: PlayerCanvasNode(frame: CGRect(x: 240, y: 190, width: 260, height: 260))])
        driver.move(to: a, key: key(false), animated: false)
        driver.move(to: b, key: key(false), animated: true)
        try require(driver.pose == b && !driver.isAnimating && notifications == 0,
                    "Normal geometry change caused a second published layout pass")
        driver.move(to: a, key: key(true), animated: true)
        try require(driver.isAnimating && notifications == 1, "Animation start did not publish one coherent state")
        clock.time += 0.1; driver.advance(to: clock.time)
        try require(notifications == 2, "One animation frame published multiple invalidations")
        clock.time += 2; driver.advance(to: clock.time)
        try require(!driver.isAnimating && driver.pose == a && notifications == 3,
                    "Animation endpoint did not publish one settled state")
        driver.move(to: a, key: key(true), animated: true)
        try require(notifications == 3, "Unchanged idle state published another update")
    }

    @MainActor private static func checkDeterministicDriver() throws -> [String: Double] {
        let clock = ResponsiveTestClock()
        let driver = PlayerResponsiveMotionDriver(automaticallyTicks: false, now: { clock.time })
        let a = PlayerCanvasPose(nodes: [.artwork: PlayerCanvasNode(frame: CGRect(x: 20, y: 30, width: 100, height: 100))])
        let b = PlayerCanvasPose(nodes: [.artwork: PlayerCanvasNode(frame: CGRect(x: 240, y: 190, width: 260, height: 260))])
        let ka = key(false), kb = key(true), start = clock.time
        driver.move(to: a, key: ka, animated: false); driver.move(to: b, key: kb, animated: true)
        driver.advance(to: start + 0.1)
        let progress = (driver.pose![.artwork].frame.minX - 20) / 220
        let expected = 1 - (1 + 1.6) * exp(-1.6)
        try require(abs(progress - expected) < 0.000001, "Motion was linear or differed from the critical spring")
        let epsilon = 0.000001
        driver.advance(to: start + 0.1 - epsilon); let left = driver.pose![.artwork].frame.minX
        driver.advance(to: start + 0.1); let center = driver.pose!
        clock.time = start + 0.1; driver.move(to: a, key: ka, animated: true)
        let jump = poseDistance(center, driver.pose!)
        try require(jump < 0.000001, "Retargeting jumped position")
        driver.advance(to: clock.time + epsilon); let right = driver.pose![.artwork].frame.minX
        let velocityDifference = abs((center[.artwork].frame.minX - left) / epsilon - (right - center[.artwork].frame.minX) / epsilon)
        try require(velocityDifference < 0.5, "Retargeting discarded current velocity")
        driver.advance(to: clock.time + 2)
        try require(!driver.isAnimating && !driver.hasScheduledTimer, "Controlled driver did not become idle")
        return ["positionJump": jump, "velocityDifference": velocityDifference, "nonlinearProgressAt100ms": progress]
    }

    @MainActor private static func checkAutomaticTimer() async throws {
        let driver = PlayerResponsiveMotionDriver()
        let a = PlayerCanvasPose(nodes: [.artwork: PlayerCanvasNode(frame: CGRect(x: 0, y: 0, width: 100, height: 100))])
        let b = PlayerCanvasPose(nodes: [.artwork: PlayerCanvasNode(frame: CGRect(x: 200, y: 150, width: 260, height: 260))])
        driver.move(to: a, key: key(false), animated: false)
        try require(!driver.hasScheduledTimer, "Idle driver scheduled a timer")
        driver.move(to: b, key: key(true), animated: true)
        try require(driver.hasScheduledTimer && driver.isAnimating, "Default common timer did not start")
        try await Task.sleep(for: .milliseconds(100))
        let x = driver.pose![.artwork].frame.minX
        try require(x > 0 && x < 200, "Default timer did not publish an intermediate model rectangle")
        // Run only this process's native tracking mode; no input is posted.
        driveTrackingMode(for: 0.08)
        try require(driver.pose![.artwork].frame.minX > x + 1, "Common timer stopped advancing in event-tracking mode")
        let deadline = Date().addingTimeInterval(2)
        while driver.isAnimating && Date() < deadline { try await Task.sleep(for: .milliseconds(40)) }
        try require(!driver.isAnimating && !driver.hasScheduledTimer && driver.pose == b, "Default timer did not stop at its target")
        driver.stop(); try require(driver.pose == nil && !driver.hasScheduledTimer, "Stopping left stale timer/geometry")
    }

    @MainActor private static func driveTrackingMode(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            _ = RunLoop.current.run(mode: .eventTracking, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    @MainActor private static func checkMarkerOwnership() throws {
        let first = NSScrollView(), second = NSScrollView()
        first.identifier = NSUserInterfaceItemIdentifier("original-first")
        let a = NSView(), b = NSView(); first.documentView = a; second.documentView = b
        let marker = PlayerPlaybackScrollIdentity.MarkerView()
        a.addSubview(marker)
        try require(marker.enclosingScrollView === first && first.identifier == PlayerPlaybackScrollIdentity.scrollIdentifier, "Marker did not bind actual ancestor")
        marker.removeFromSuperview(); try require(first.identifier?.rawValue == "original-first", "Marker did not restore original identifier")
        b.addSubview(marker); second.identifier = NSUserInterfaceItemIdentifier("external-owner")
        marker.removeFromSuperview(); try require(second.identifier?.rawValue == "external-owner", "Marker overwrote external owner on detach")
    }

    private static func key(_ compact: Bool) -> PlayerCanvasMotionKey {
        PlayerCanvasMotionKey(compact: compact, cover: true, page: .playback, lyrics: false, controls: true, progress: true, transport: true)
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func poseDistance(_ a: PlayerCanvasPose, _ b: PlayerCanvasPose) -> Double {
        PlayerCanvasElement.allCases.map { element in
            zip(rectArray(a[element].frame), rectArray(b[element].frame)).map { abs($0 - $1) }.max() ?? 0
        }.max() ?? 0
    }
    private static func markerBounds(_ image: NSBitmapImageRep, size: CGSize) -> (red: CGRect?, green: CGRect?) {
        guard let cgImage = image.cgImage else { return (nil, nil) }
        let width = max(1, Int(ceil(size.width))), height = max(1, Int(ceil(size.height)))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        struct Box {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1, count = 0
            mutating func add(_ x: Int, _ y: Int) { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y); count += 1 }
            func rect() -> CGRect? { count > 3 ? CGRect(x: minX, y: minY, width: maxX - minX + 2, height: maxY - minY + 2) : nil }
        }
        return data.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, nil) }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = raw.bindMemory(to: UInt8.self)
            var red = Box(), green = Box()
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 0, to: width, by: 2) {
                    let offset = (y * width + x) * 4
                    let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
                    guard pixels[offset + 3] > 200 else { continue }
                    if r > 190 && r * 10 > g * 18 && r * 10 > b * 18 { red.add(x, y) }
                    if g > 190 && g * 10 > r * 18 && g * 10 > b * 18 { green.add(x, y) }
                }
            }
            return (red.rect(), green.rect())
        }
    }
    private static func rectArray(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map(Double.init) }
    private static func close(_ a: [Double]?, _ b: [Double]?, tolerance: Double) -> Bool {
        guard let a, let b else { return false }; return zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }
    private static func between(_ sample: [String: Any], from first: [String: Any], to last: [String: Any]) -> Bool {
        guard let value = sample["artworkMarker"] as? [Double], let a = first["artworkMarker"] as? [Double], let b = last["artworkMarker"] as? [Double] else { return false }
        return !close(value, a, tolerance: 4) && !close(value, b, tolerance: 4)
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "PlayerResponsiveMotion", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    private static func require(_ value: Bool, _ text: String) throws { if !value { throw failure(text) } }
}
