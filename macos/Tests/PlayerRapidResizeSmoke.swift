import AppKit
import SwiftUI

private final class RapidResizePanel: NSPanel {
    var simulatedLiveResize = false
    override var inLiveResize: Bool { simulatedLiveResize || super.inLiveResize }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
@MainActor private final class RapidResizeHostingView<Content: View>: NSHostingView<Content> {
    var afterNativeLayout: (() -> Void)?
    override func layout() {
        super.layout()
        afterNativeLayout?()
    }
}
@MainActor private final class RapidResizeClock { var time: TimeInterval = 10_000 }

@main struct PlayerRapidResizeSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("FAIL: rapid resize timed out\n".utf8)); exit(124)
        }
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }

    @MainActor private static func check() async throws {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.rapid-resize-check",
              let rootPath = env["FUSIONPLAY_RAPID_ROOT"], let outputPath = env["FUSIONPLAY_RAPID_OUTPUT"] else {
            throw failure("Unexpected isolated fixture")
        }
        let expectedReproduction = env["FUSIONPLAY_RAPID_MODE"] == "before"
        var errors: [String] = [], cases: [[String: Any]] = []
        for layout in [NarrowPlayerLayout.original, .squarePaged, .ipadPaged] {
            let result = try await run(layout: layout, root: URL(fileURLWithPath: rootPath),
                strictImmediate: env["FUSIONPLAY_RAPID_MODE"]?.hasPrefix("after") == true, errors: &errors)
            cases.append(result)
        }
        let reproduced = cases.contains { $0["rootMinimumCropReproduced"] as? Bool == true }
        let passed = expectedReproduction ? reproduced : errors.isEmpty
        let report: [String: Any] = ["passed": passed, "expectedBeforeReproduction": expectedReproduction,
            "expectedReproductionObserved": expectedReproduction && reproduced,
            "forcedUndersizeWitnessObserved": reproduced, "layoutRegressionPassed": !expectedReproduction && errors.isEmpty,
            "errors": errors, "cases": cases,
            "windowOrdered": false, "systemInputPosted": false, "screenCaptured": false,
            "bitmapCaptured": false, "receiverStarted": false, "realPreferencesChanged": false,
            "nativeLiveResizeSimulated": true,
            "trajectory": [760, 600, 599, 320, 280, 260, 280, 599, 600, 599, 260],
            "programmaticRecoveryWidth": 211]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outputPath))
        if !passed { throw failure(expectedReproduction ? "Before fixture did not reproduce the known crop" : errors.joined(separator: " | ")) }
        if expectedReproduction {
            print("PASS: expected BEFORE crop reproduction only; this is not layout acceptance")
            return
        }
        print("PASS: all three real PlayerView layouts, rapid width reversals, own live-resize notifications, 211-point recovery, native role/clip/anchor checks; no windows ordered or images captured")
    }

    @MainActor private static func run(layout: NarrowPlayerLayout, root: URL, strictImmediate: Bool, errors: inout [String]) async throws -> [String: Any] {
        UserDefaults.standard.setVolatileDomain([
            "appLanguage": "en", NarrowPlayerLayout.storageKey: layout.rawValue,
            LyricsDisplayMode.storageKey: LyricsDisplayMode.automatic.rawValue,
            "playerControlsAlwaysVisible": true, "playerShowsLyricsButton": true,
            "playerShowsTransport": true, "playerShowsProgress": true,
            "coverPlayerShowsTransport": true, "coverPlayerShowsProgress": true,
            "albumPlayerShowsTransport": true, "albumPlayerShowsProgress": true,
            "wrapPlayerMetadata": false, "playerWindowPinned": false, "playerShowsPinButton": false,
            "coverLyricsExpandedByDragging": false, "lyricsPageShowsArtwork": true, "lyricsPageShowsTrackInfo": true,
            "uiFontFamily": "", "uiFontWeight": 400, "lyricsFontScalePercent": 100,
            "staggerLyricMotion": true, "lyricStaggerMilliseconds": 140, "lyricLineMoveMilliseconds": 420
        ], forName: UserDefaults.argumentDomain)
        let lyrics = (0..<16).map { index in
            String(format: "[%02d:%02d]", index * 6 / 60, index * 6 % 60)
                + "A changing light across the mountains and the sea, another quiet morning \(index)"
        }.joined(separator: "\n")
        let state = Snapshot(phase: .paused, title: "Rapid resize fixture title", artist: "Synthetic Artist",
            album: "Synthetic Album", trackId: "rapid-" + layout.rawValue, artworkUrl: "", lyricsText: lyrics,
            durationMs: 180_000, positionMs: 36_000, controlsAvailable: true, volume: 50,
            message: "", address: "", output: "", queueMs: 0, outputLatencyMs: 0,
            scheduleErrorMs: 0, underruns: 0, droppedFrames: 0, resyncs: 0)
        let artwork = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
            NSColor.systemIndigo.setFill(); rect.fill(); return true
        }
        let model = ReceiverModel.preview(state, artwork: artwork, root: root)
        let clock = RapidResizeClock()
        let motion = PlayerResponsiveMotionDriver(automaticallyTicks: false, now: { clock.time })
        let host = RapidResizeHostingView(rootView: PlayerView(model: model, responsiveMotion: motion).appTypography())
        let window = RapidResizePanel(contentRect: CGRect(x: 0, y: 0, width: 760, height: 900),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true; window.contentView = host
        defer { host.afterNativeLayout = nil; motion.stop(); window.contentView = nil; window.close() }
        var rows: [[String: Any]] = []
        var localErrors: [String] = []
        var rootMinimumCropReproduced = false
        var immediateAnchors: [[String: Any]] = []
        var immediateAttempts = 0
        var readingImmediate = false
        var phase = "initial"
        func captureImmediateAnchor() {
            guard window.inLiveResize, !readingImmediate else { return }
            readingImmediate = true
            defer { readingImmediate = false }
            immediateAttempts += 1
            guard immediateAnchors.count < 1024 else { return }
            let nodes = descendants(host)
            guard let source = nodes.compactMap({ $0 as? LyricsRowGeometryCheckView }).first(where: { $0.anchor?.heldReadingPoint != nil }),
                  let anchor = source.anchor, let held = anchor.heldReadingPoint,
                  let scroll = anchor.boundScrollForCheck,
                  let row = nodes.compactMap({ $0 as? LyricsRowGeometryCheckView }).first(where: { $0.lineID == held.id }) else { return }
            let clip = scroll.contentView, rect = row.convert(row.bounds, to: clip)
            let top = clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
            let actual = top + rect.height * held.rowFraction, desired = clip.bounds.height * held.viewportFraction
            immediateAnchors.append(["phase": phase, "stage": "root-host-post-super.layout-before-yield",
                "clock": clock.time, "id": held.id, "viewportFraction": Double(held.viewportFraction),
                "error": Double(actual - desired), "actualY": Double(actual), "desiredY": Double(desired),
                "windowSize": [window.contentRect(forFrameRect: window.frame).width, window.contentRect(forFrameRect: window.frame).height],
                "hostSize": [host.bounds.width, host.bounds.height], "rowFrame": rectArray(rect),
                "clipBounds": rectArray(clip.bounds), "rowNeedsLayout": row.needsLayout,
                "scrollNeedsLayout": scroll.needsLayout, "clipNeedsLayout": clip.needsLayout])
        }
        host.afterNativeLayout = { captureImmediateAnchor() }
        func note(_ condition: Bool, _ message: String) {
            if !condition { localErrors.append(layout.rawValue + ": " + message) }
        }
        func pump(_ milliseconds: Int = 20) async {
            host.needsLayout = true; host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(milliseconds))
            host.layoutSubtreeIfNeeded()
        }
        func expected(_ size: CGSize) -> PlayerCanvasPose {
            let typography = AppTypography()
            return PlayerResponsiveLayout(size: size, layout: layout, showLyrics: true, page: .playback,
                showControls: true, showsProgress: true, showsTransport: true, headerArtwork: true, headerInfo: true,
                wraps: false, coverTitleLines: 1, coverSubtitleLines: 1) { width, titleSize, subtitleSize, spacing, titleLines, subtitleLines in
                    PlayerTrackMetadataView.height(title: state.title, subtitle: state.artist + " - " + state.album,
                        width: width, titleFont: typography.nsFont(size: titleSize, weight: .semibold),
                        subtitleFont: typography.nsFont(size: subtitleSize), spacing: spacing,
                        wraps: false, wrappedTitleLines: titleLines, wrappedSubtitleLines: subtitleLines)
                }.pose
        }
        func awaitTarget(_ phase: String) async {
            for _ in 0..<40 {
                await pump(10)
                let physical = window.contentRect(forFrameRect: window.frame).size
                let effective = CGSize(width: max(260, physical.width), height: max(260, physical.height))
                if let accepted = motion.targetPoseForCheck,
                   distance(accepted, expected(effective)) < 0.5 { return }
            }
            note(false, "latest target never accepted real width/height in " + phase)
        }
        func capture(_ phase: String, requested: CGFloat? = nil, validate: Bool = true) {
            let physical = window.contentRect(forFrameRect: window.frame).size
            let target = motion.targetPoseForCheck
            let display = motion.isAnimating ? motion.pose : target
            var sample: [String: Any] = ["phase": phase, "requestedWidth": requested as Any? ?? NSNull(),
                "windowSize": [physical.width, physical.height], "hostSize": [host.bounds.width, host.bounds.height],
                "hostClass": String(reflecting: type(of: host)), "hostSizingOptions": host.sizingOptions.rawValue,
                "minimum": [window.contentMinSize.width, window.contentMinSize.height],
                "ratio": [window.contentAspectRatio.width, window.contentAspectRatio.height],
                "liveResize": window.inLiveResize, "animating": motion.isAnimating,
                "timer": motion.hasScheduledTimer]
            var roles: [String: Any] = [:], scrollers: [[String: Any]] = []
            var nativeRoles: [PlayerCanvasElement: CGRect] = [:]
            let nodes = descendants(host)
            let attachments = nodes.compactMap { $0 as? PlayerWindowBehavior.WindowAttachmentView }
            sample["windowPolicyAttachmentCount"] = attachments.count
            sample["windowPolicyAttachmentTypes"] = attachments.map { String(reflecting: type(of: $0)) }
            sample["windowPolicyAttachmentsOwnWindow"] = attachments.allSatisfy { $0.window === window }
            if validate { note(attachments.count == 1, phase + " player window policy attachment is not unique") }
            for element in [PlayerCanvasElement.artwork, .metadata, .progress, .lyrics] {
                if let view = nodes.first(where: { $0.identifier?.rawValue == "fusionplay.player.hit-area." + element.rawValue }) {
                    let rect = view.convert(view.bounds, to: host)
                    nativeRoles[element] = rect
                    roles[element.rawValue] = ["native": rectArray(rect),
                        "target": target.map { rectArray($0[element].frame) } as Any? ?? NSNull(),
                        "presentation": display.map { rectArray($0[element].frame) } as Any? ?? NSNull()]
                    if validate, let display, display[element].opacity > 0.5 {
                        note(abs(rect.minX - display[element].frame.minX) < 1,
                             phase + " role x differs from latest presentation: " + element.rawValue)
                        note(abs(view.bounds.width - display[element].frame.width) < 1,
                             phase + " role width differs from presentation: " + element.rawValue)
                    }
                }
            }
            for scroll in nodes.compactMap({ $0 as? NSScrollView }) {
                let playback = scroll.identifier?.rawValue == "fusionplay.player.playback-scroll"
                scrollers.append(["playback": playback, "frame": rectArray(scroll.convert(scroll.bounds, to: host)),
                    "clip": rectArray(scroll.contentView.bounds), "documentFrame": scroll.documentView.map { rectArray($0.frame) } as Any? ?? NSNull(),
                    "documentBounds": scroll.documentView.map { rectArray($0.bounds) } as Any? ?? NSNull()])
                if validate && playback {
                    note(abs(scroll.contentView.bounds.minX) < 1, phase + " playback clip acquired horizontal offset")
                    note(abs(scroll.bounds.width - host.bounds.width) < 1, phase + " playback viewport does not match host width")
                }
            }
            sample["roles"] = roles; sample["scrollers"] = scrollers
            if phase == "forced-211-before-end", let target, let art = nativeRoles[.artwork] {
                let mismatch = physical.width < 260 && target[.artwork].frame.width > physical.width + 1 && art.minX < -1
                sample["rootMinimumProposalMismatch"] = mismatch
                rootMinimumCropReproduced = rootMinimumCropReproduced || mismatch
            }
            if validate && !window.inLiveResize && !motion.isAnimating {
                let aspect = window.contentAspectRatio
                if aspect.width > 0 && aspect.height > 0 {
                    let ratio = aspect.width / aspect.height
                    let required = CGSize(width: ceil(260 * max(1, ratio)), height: ceil(260 * max(1, 1 / ratio)))
                    sample["ratioRequiredMinimumContent"] = [required.width, required.height]
                    // contentMinSize may be stricter by the native titlebar's
                    // height; a larger height is valid in the contentRect units.
                    sample["nativeChromeHeight"] = max(0, window.frame.height - physical.height)
                    note(window.contentMinSize.width >= required.width - 0.5
                        && window.contentMinSize.height >= required.height - 0.5,
                        phase + " native minimum is incompatible with the content aspect ratio")
                }
                if physical.width < 600, layout.isCover, let art = nativeRoles[.artwork] {
                    note(abs(art.minX) < 0.5 && abs(art.width - host.bounds.width) < 0.5,
                         phase + " settled native artwork is shifted or wider than the host")
                }
                if let target {
                    for element in [PlayerCanvasElement.metadata, .progress] where target[element].opacity > 0.5 {
                        if let rect = nativeRoles[element] {
                            note(rect.minX >= 15.5 && rect.maxX <= physical.width - 15.5,
                                 phase + " settled metadata/progress horizontal margin was clipped: " + element.rawValue)
                        }
                    }
                }
            }
            if let point = nodes.compactMap({ $0 as? LyricsRowGeometryCheckView }).first(where: { $0.anchor?.heldReadingPoint != nil }),
               let anchor = point.anchor, let held = anchor.heldReadingPoint,
               let scroll = anchor.boundScrollForCheck,
               let heldRow = nodes.compactMap({ $0 as? LyricsRowGeometryCheckView }).first(where: { $0.lineID == held.id }) {
                let clip = scroll.contentView, rect = heldRow.convert(heldRow.bounds, to: clip)
                let top = clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
                let actual = top + rect.height * held.rowFraction, desired = clip.bounds.height * held.viewportFraction
                let rowInHost = heldRow.convert(heldRow.bounds, to: host)
                let hostReadingY = host.isFlipped ? rowInHost.minY + rowInHost.height * held.rowFraction
                    : rowInHost.maxY - rowInHost.height * held.rowFraction
                sample["anchor"] = ["id": held.id, "actualY": Double(actual), "desiredY": Double(desired),
                    "error": Double(actual - desired), "viewportFraction": Double(held.viewportFraction),
                    "hostReadingY": Double(hostReadingY), "rowHostFrame": rectArray(rowInHost)]
                if validate && window.inLiveResize {
                    note(abs(actual - desired) < 2, phase + " held lyric reading point moved vertically")
                }
            }
            if validate {
                note(physical.width >= 259.5 && physical.height >= 259.5, phase + " native content fell below minimum")
                note(abs(host.bounds.width - physical.width) < 0.5, phase + " host and native window width disagree")
                note(!window.isVisible && !window.isKeyWindow && !window.isMainWindow && window.alphaValue == 0
                    && NSApp.activationPolicy() == .prohibited, phase + " fixture became visible/active")
                if !motion.isAnimating, physical.width < 600, layout.isCover, let target {
                    note(abs(target[.artwork].frame.width - physical.width) < 0.5, phase + " root minimum proposal clips the native window")
                    note(target[.metadata].frame.minX >= 15.5, phase + " metadata lost its horizontal inset")
                }
            }
            rows.append(sample)
        }
        await awaitTarget("initial"); clock.time += 2; motion.advance(to: clock.time); await pump(900)
        capture("initial")
        window.simulatedLiveResize = true
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        await pump(25)
        for (index, width) in [760.0, 600, 599, 320, 280, 260, 280, 599, 600, 599, 260].enumerated() {
            phase = "rapid-\(index)"
            window.setContentSize(CGSize(width: width, height: 900))
            await awaitTarget("rapid-\(index)")
            clock.time += [0.0, 0.016, 0.04, 0.12][index % 4]
            motion.advance(to: clock.time); await pump(20)
            capture("rapid-\(index)-frame-0", requested: width)
            for frame in 1...2 {
                clock.time += 1.0 / 60; motion.advance(to: clock.time)
                await pump(17)
                capture("rapid-\(index)-frame-\(frame)", requested: width)
            }
        }
        window.simulatedLiveResize = false
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        await awaitTarget("rapid-end"); clock.time += 2; motion.advance(to: clock.time); await pump(1200)
        capture("rapid-end")
        window.simulatedLiveResize = true
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        phase = "forced-211"
        window.setContentSize(CGSize(width: 211, height: 614)); await pump(40)
        capture("forced-211-before-end", requested: 211, validate: false)
        window.simulatedLiveResize = false
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        await awaitTarget("forced-211-recovery"); clock.time += 2; motion.advance(to: clock.time); await pump(1200)
        capture("forced-211-recovery", requested: 211)
        // Re-run the real representable policy updates as ordinary media ticks
        // would, then begin/end another native tracking interval. This remains
        // an unordered NSPanel fixture, not a SwiftUI Window scene acceptance.
        for index in 0..<3 {
            var updated = state
            updated.positionMs = 37_000 + UInt64(index) * 1_000
            model.snapshot = updated
            await awaitTarget("media-\(index)")
            clock.time += 2; motion.advance(to: clock.time); await pump(60)
            capture("media-\(index)")
        }
        window.simulatedLiveResize = true
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        await pump(40); capture("media-live-begin")
        window.simulatedLiveResize = false
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        await awaitTarget("media-live-end")
        clock.time += 2; motion.advance(to: clock.time); await pump(120)
        capture("media-live-end")
        note(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "fixture took foreground")
        let immediateErrors = immediateAnchors.compactMap { $0["error"] as? Double }
        var immediateJump = 0.0
        for pair in zip(immediateAnchors, immediateAnchors.dropFirst()) {
            guard pair.0["id"] as? Int == pair.1["id"] as? Int,
                  let aFraction = pair.0["viewportFraction"] as? Double,
                  let bFraction = pair.1["viewportFraction"] as? Double, abs(aFraction - bFraction) < 0.001,
                  let a = pair.0["error"] as? Double, let b = pair.1["error"] as? Double else { continue }
            immediateJump = max(immediateJump, abs(a - b))
        }
        if strictImmediate {
            if layout == .original { note(!immediateErrors.isEmpty, "no immediate post-layout anchor samples captured") }
            note(immediateErrors.allSatisfy { abs($0) <= 1 }, "post-layout-before-yield reading point drift exceeded 1pt")
        }
        let immediateStats: [String: Any] = ["attempts": immediateAttempts, "sampleCount": immediateErrors.count,
            "minimumError": immediateErrors.min() as Any? ?? NSNull(),
            "maximumError": immediateErrors.max() as Any? ?? NSNull(),
            "maximumAbsoluteError": immediateErrors.map(abs).max() as Any? ?? NSNull(),
            "maximumSameReadingPointErrorJump": immediateJump,
            "strictThresholdPoints": strictImmediate ? 1 : NSNull(),
            "scope": strictImmediate ? "strict native post-layout geometry" : "record only in window-policy isolation"]
        let anchors = rows.filter { $0["liveResize"] as? Bool == true }.compactMap { $0["anchor"] as? [String: Any] }
        let anchorErrors = anchors.compactMap { $0["error"] as? Double }
        var maxErrorJump = 0.0
        for pair in zip(anchors, anchors.dropFirst()) {
            guard pair.0["id"] as? Int == pair.1["id"] as? Int,
                  let aFraction = pair.0["viewportFraction"] as? Double,
                  let bFraction = pair.1["viewportFraction"] as? Double, abs(aFraction - bFraction) < 0.001,
                  let a = pair.0["error"] as? Double, let b = pair.1["error"] as? Double else { continue }
            maxErrorJump = max(maxErrorJump, abs(a - b))
        }
        let anchorStats: [String: Any] = ["liveSampleCount": anchorErrors.count,
            "minimumError": anchorErrors.min() as Any? ?? NSNull(),
            "maximumError": anchorErrors.max() as Any? ?? NSNull(),
            "maximumAbsoluteError": anchorErrors.map(abs).max() as Any? ?? NSNull(),
            "maximumSameReadingPointErrorJump": maxErrorJump,
            "cadence": "three native geometry samples per width; later two fake-clock steps 1/60s; not display FPS"]
        if layout == .original { note(!anchorErrors.isEmpty, "no live native reading-point samples were captured") }
        errors.append(contentsOf: localErrors)
        print("\(localErrors.isEmpty ? "PASS" : "FAIL") \(layout.rawValue): \(rows.count) native samples; errors=\(localErrors.count); anchor max=\(anchorErrors.map(abs).max() ?? -1), jump=\(maxErrorJump)")
        return ["layout": layout.rawValue, "passed": localErrors.isEmpty,
            "rootMinimumCropReproduced": rootMinimumCropReproduced, "anchorStatistics": anchorStats,
            "immediateAnchorStatistics": immediateStats, "immediateAnchorSamples": immediateAnchors,
            "errors": localErrors, "samples": rows]
    }

    private static func rectArray(_ value: CGRect) -> [Double] { [value.minX, value.minY, value.width, value.height].map(Double.init) }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func distance(_ a: PlayerCanvasPose, _ b: PlayerCanvasPose) -> CGFloat {
        PlayerCanvasElement.allCases.flatMap { element in zip(rectArray(a[element].frame), rectArray(b[element].frame)).map { CGFloat(abs($0 - $1)) } }.max() ?? 0
    }
    private static func failure(_ text: String) -> NSError { NSError(domain: "PlayerRapidResize", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
