import AppKit
import Darwin
import ScreenCaptureKit
import SwiftUI

@main struct PlayerNarrowWindowSmoke: App {
    @StateObject private var model: ReceiverModel
    init() {
        precondition(Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.narrow-ui-check")
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        defaults.register(defaults: ["appLanguage": "en", NarrowPlayerLayout.storageKey: NarrowPlayerLayout.ipadPaged.rawValue,
            "playerLyricsDisplayMode": "never", "playerControlsAlwaysVisible": true,
            "playerShowsProgress": true, "playerShowsTransport": true, "playerShowsLyricsButton": true,
            "lyricsPageShowsArtwork": true, "lyricsPageShowsTrackInfo": true, "wrapPlayerMetadata": false,
            "uiCorrectLyricTitles": false, "playerWindowPinned": false, "playerShowsPinButton": false])
        let state = Snapshot(phase: .playing,
            title: "A deliberately long synthetic song title to verify narrow-window wrapping and control space",
            artist: "A long synthetic artist name", album: "An equally long synthetic album title",
            trackId: "narrow-preview", artworkUrl: "",
            lyricsText: "[00:00]Opening lyric in the current track\n[00:06]A new line to read\n[00:12]Another synthetic lyric line\n[00:20]A final line",
            durationMs: 180_000, positionMs: 8_000, controlsAvailable: true, volume: 50,
            message: "", address: "", output: "", queueMs: 0, outputLatencyMs: 0, scheduleErrorMs: 0,
            underruns: 0, droppedFrames: 0, resyncs: 0)
        let art = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            NSGradient(starting: .systemIndigo, ending: .systemPink)?.draw(in: rect, angle: 45)
            return true
        }
        _model = StateObject(wrappedValue: ReceiverModel.preview(state, artwork: art,
            root: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FUSIONPLAY_NARROW_CHECK_ROOT"]!)))
    }
    var body: some Scene {
        Window("Narrow Player UI Check", id: "narrow-ui") {
            PlayerView(model: model).appTypography().environment(\.locale, Locale(identifier: "en"))
                .background(NarrowWindowProbe(model: model).frame(width: 0, height: 0))
        }.defaultSize(width: 260, height: 260).windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
    }
}

private struct NarrowWindowProbe: NSViewRepresentable {
    let model: ReceiverModel
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.model = model; return view }
    func updateNSView(_ view: Probe, context: Context) {}
    final class Probe: NSView {
        var model: ReceiverModel?
        private var started = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !started else { return }; started = true
            NSApp.setActivationPolicy(.accessory)
            window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                await check(window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { exit(124) }
        }
        @MainActor private func check(_ window: NSWindow) async {
            let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FUSIONPLAY_NARROW_CHECK_OUTPUT"]!)
            let defaults = UserDefaults.standard
            var records: [[String: Any]] = []
            var compositorAvailable = true
            var initialScrollIDs: Set<ObjectIdentifier>?
            func attribute(_ object: NSObject, _ key: String) -> Any? {
                let getter = "is" + key.prefix(1).uppercased() + key.dropFirst()
                guard object.responds(to: NSSelectorFromString(key)) || object.responds(to: NSSelectorFromString(getter)) else { return nil }
                return object.value(forKey: key)
            }
            func nodes() -> [NSObject] {
                var queue: [NSObject] = [window], seen = Set<ObjectIdentifier>(), result: [NSObject] = []
                while let node = queue.popLast(), result.count < 4000 {
                    guard seen.insert(ObjectIdentifier(node)).inserted else { continue }; result.append(node)
                    if let children = attribute(node, "accessibilityChildren") as? [NSObject] { queue += children }
                    else if let view = node as? NSView { queue += view.subviews }
                    if let owner = node as? NSWindow, let content = owner.contentView { queue.append(content) }
                }
                return result
            }
            func button(_ id: String) -> NSObject? {
                nodes().first { attribute($0, "accessibilityIdentifier") as? String == id }
            }
            func press(_ id: String) -> String {
                guard let node = button(id) else { return "button-unavailable" }
                if let native = node as? NSButton { native.performClick(nil); return "native-button" }
                let selector = NSSelectorFromString("accessibilityPerformPress")
                if node.responds(to: selector) {
                    typealias Action = @convention(c) (AnyObject, Selector) -> Bool
                    if unsafeBitCast(node.method(for: selector), to: Action.self)(node, selector) { return "public-AX-press" }
                }
                guard let frame = (attribute(node, "accessibilityFrame") as? NSValue)?.rectValue else { return "AX-frame-unavailable" }
                let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                let stamp = ProcessInfo.processInfo.systemUptime
                guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                    timestamp: stamp, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                      let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                    timestamp: stamp + 0.03, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0) else { return "own-window-event-unavailable" }
                NSApp.postEvent(down, atStart: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { NSApp.postEvent(up, atStart: false) }
                return "own-window-pointer-events"
            }
            func nativeDescendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(nativeDescendants) }
            func nativeScrolls() -> [NSScrollView] { window.contentView.map(nativeDescendants)?.compactMap { $0 as? NSScrollView } ?? [] }
            func viewportScreen(_ scroll: NSScrollView) -> NSRect {
                window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
            }
            func scrollForRow(_ row: NSRect, in scrolls: [NSScrollView]) -> NSScrollView? {
                scrolls.max { left, right in
                    let l = viewportScreen(left).intersection(row)
                    let r = viewportScreen(right).intersection(row)
                    return (l.isNull ? 0 : l.width) < (r.isNull ? 0 : r.width)
                }
            }
            func revealSummary() {
                guard let node = button("fusionplay.player.lyric-summary"),
                      let frame = (attribute(node, "accessibilityFrame") as? NSValue)?.rectValue,
                      let scroll = nativeScrolls().max(by: { viewportScreen($0).intersection(window.frame).width < viewportScreen($1).intersection(window.frame).width }),
                      let document = scroll.documentView else { return }
                let local = document.convert(window.convertFromScreen(frame), from: nil)
                document.scrollToVisible(local.insetBy(dx: 0, dy: -8))
            }
            func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }
            func capture(_ name: String, action: String? = nil) async {
                var entry: [String: Any] = ["name": name, "windowContent": NSStringFromSize(window.contentRect(forFrameRect: window.frame).size),
                    "minimum": NSStringFromSize(window.contentMinSize), "aspect": NSStringFromSize(window.contentAspectRatio),
                    "savedLyricsMode": defaults.string(forKey: "playerLyricsDisplayMode") ?? "",
                    "layoutMode": defaults.string(forKey: NarrowPlayerLayout.storageKey) ?? "", "action": action as Any? ?? NSNull(),
                    "lyricSummaryAccessible": button("fusionplay.player.lyric-summary") != nil,
                    "lyricsHeaderAccessible": button("fusionplay.player.lyrics.header") != nil]
                let currentRows = nodes().filter { attribute($0, "accessibilityValue") as? String == "Current Lyric" }
                let scrollViews = nativeScrolls()
                if !name.hasPrefix("stacked"), let root = window.contentView,
                   let region = nativeDescendants(root).first(where: { $0.identifier?.rawValue == "fusionplay.player.horizontal-paging-region" }) {
                    precondition(region.bounds.width >= window.contentRect(forFrameRect: window.frame).width,
                                 "Paging input region has no usable width")
                    precondition(region.hitTest(NSPoint(x: region.bounds.midX, y: region.bounds.midY)) == nil,
                                 "Transparent paging monitor intercepted native mouse controls")
                    entry["pagingMonitorPassesMouseInput"] = true
                }
                if !name.hasPrefix("stacked"), !name.contains("lyrics"), let artwork = button("fusionplay.player.paged-artwork"),
                   let frame = (attribute(artwork, "accessibilityFrame") as? NSValue)?.rectValue {
                    precondition(abs(frame.width - frame.height) < 1, "Paged artwork was distorted into a rectangle")
                    entry["squareArtwork"] = NSStringFromRect(frame)
                }
                let scrollIDs = Set(scrollViews.map(ObjectIdentifier.init))
                if name.hasPrefix("paged-"), !name.hasPrefix("paged-empty"), let initialScrollIDs {
                    precondition(initialScrollIDs.isSubset(of: scrollIDs), "Page activation recreated the original lyric scroll view")
                } else if initialScrollIDs == nil, !scrollIDs.isEmpty { initialScrollIDs = scrollIDs }
                if name == "paged-260-current-lyric-summary" {
                    guard let summary = button("fusionplay.player.lyric-summary"),
                          let frame = (attribute(summary, "accessibilityFrame") as? NSValue)?.rectValue,
                          let scroll = scrollForRow(frame, in: scrollViews) else { preconditionFailure("No reachable current lyric summary") }
                    let viewport = viewportScreen(scroll)
                    precondition(frame.minY >= viewport.minY - 1 && frame.maxY <= viewport.maxY + 1,
                                 "The short playback page could not scroll its lyric summary fully into view")
                    precondition(scroll.documentVisibleRect.minY > 0, "The short playback column did not scroll")
                    entry["summaryFullyVisibleAfterNativeScroll"] = true
                }
                if name.hasSuffix("-settled") {
                    precondition(currentRows.count == 1 && !scrollViews.isEmpty, "Expected a real current lyric and viewport")
                    let row = (attribute(currentRows[0], "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                    let viewport = viewportScreen(scrollForRow(row, in: scrollViews)!)
                    let fraction = (viewport.maxY - row.maxY) / viewport.height
                    precondition(row.minY >= viewport.minY - 1 && row.maxY <= viewport.maxY + 1,
                                 "Current lyric is clipped outside the presented viewport")
                    precondition(fraction >= 0.05 && fraction < 0.42,
                                 "Current lyric is outside the clear upper reading region: \(fraction)")
                    entry["currentLyricInClearReadingRegion"] = true
                }
                entry["currentLyricRows"] = currentRows.map { row -> [String: Any] in
                    let rect = (attribute(row, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
                    var metrics: [String: Any] = ["frameScreen": NSStringFromRect(rect),
                        "label": attribute(row, "accessibilityLabel") as? String ?? "", "role": attribute(row, "accessibilityRole") as? String ?? ""]
                    if let scroll = scrollForRow(rect, in: scrollViews) {
                        let viewport = viewportScreen(scroll)
                        metrics["viewportScreen"] = NSStringFromRect(viewport)
                        metrics["topFractionInViewport"] = viewport.height > 0 ? (viewport.maxY - rect.maxY) / viewport.height : -1
                    }
                    return metrics
                }
                entry["nativeScrollViews"] = scrollViews.map { scroll -> [String: Any] in
                    ["visibleDocument": NSStringFromRect(scroll.documentVisibleRect),
                     "clipBounds": NSStringFromRect(scroll.contentView.bounds),
                     "frameScreen": NSStringFromRect(window.convertToScreen(scroll.convert(scroll.bounds, to: nil)))]
                }
                if compositorAvailable, #available(macOS 14.4, *) {
                    do {
                        let content = try await SCShareableContent.currentProcess
                        if let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) && $0.owningApplication?.processID == getpid() }) {
                            let config = SCStreamConfiguration(); config.showsCursor = false; config.ignoreShadowsSingleWindow = true
                            config.width = Int(window.frame.width * window.backingScaleFactor)
                            config.height = Int(window.frame.height * window.backingScaleFactor)
                            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                            let path = output.appendingPathComponent(name + ".png")
                            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: path)
                            entry["path"] = path.path
                        }
                    } catch { entry["captureError"] = String(describing: error); compositorAvailable = false }
                }
                if entry["path"] == nil, let view = window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.layoutSubtreeIfNeeded()
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        let path = output.appendingPathComponent(name + ".png")
                        do { try png.write(to: path); entry["path"] = path.path; entry["captureMethod"] = "own-view-bitmap" }
                        catch { entry["bitmapError"] = String(describing: error) }
                    }
                }
                records.append(entry); print("Recorded assembled PlayerView: " + name)
            }
            window.setContentSize(NSSize(width: 260, height: 260)); await settle()
            await capture("paged-260-nowrap-playback")
            defaults.set(true, forKey: "wrapPlayerMetadata"); await settle()
            await capture("paged-260-wrap-playback")
            revealSummary(); await settle()
            await capture("paged-260-current-lyric-summary")
            let pageAction = press("fusionplay.player.lyric-summary"); await settle()
            precondition(button("fusionplay.player.lyrics.header") != nil,
                         "Clicking the actual current-lyric summary did not open the lyrics page")
            await capture("paged-260-lyrics-header", action: pageAction)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await capture("paged-260-lyrics-header-settled")
            defaults.set(false, forKey: "lyricsPageShowsArtwork"); await settle()
            await capture("paged-260-lyrics-info-only")
            defaults.set(false, forKey: "lyricsPageShowsTrackInfo"); await settle()
            await capture("paged-260-lyrics-no-header")
            defaults.set(true, forKey: "lyricsPageShowsArtwork"); defaults.set(true, forKey: "lyricsPageShowsTrackInfo")
            window.setContentSize(NSSize(width: 420, height: 700)); await settle()
            await capture("paged-420-lyrics-header")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await capture("paged-420-lyrics-header-settled")
            let backAction = press("fusionplay.player.lyrics.header"); await settle()
            precondition(button("fusionplay.player.lyric-summary") != nil,
                         "Clicking the actual song header did not return to playback")
            await capture("paged-420-wrap-playback", action: backAction)
            defaults.set(NarrowPlayerLayout.original.rawValue, forKey: NarrowPlayerLayout.storageKey); await settle()
            await capture("stacked-restored-never")
            defaults.set(NarrowPlayerLayout.ipadPaged.rawValue, forKey: NarrowPlayerLayout.storageKey)
            if let model, var empty = model.snapshot {
                empty.trackId = "narrow-empty-preview"; empty.lyricsText = ""
                model.previewLyricsUpdate(empty)
            }
            window.setContentSize(NSSize(width: 260, height: 260)); await settle()
            revealSummary(); await settle()
            await capture("paged-empty-loading-summary")
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if let emptySummary = button("fusionplay.player.lyric-summary") {
                precondition(attribute(emptySummary, "accessibilityValue") as? String == L("暂无歌词"),
                             "Empty source did not show the local no-lyrics caption")
            } else { preconditionFailure("No clickable summary in the empty-source playback page") }
            await capture("paged-empty-lyric-summary")
            let emptyAction = press("fusionplay.player.lyric-summary"); await settle()
            precondition(button("fusionplay.player.lyrics.header") != nil, "Empty lyric summary could not navigate to lyrics")
            await capture("paged-empty-lyrics-page", action: emptyAction)
            defaults.set(NarrowPlayerLayout.squarePaged.rawValue, forKey: NarrowPlayerLayout.storageKey); await settle()
            let squareLyricsSize = window.contentRect(forFrameRect: window.frame).size
            precondition(window.contentAspectRatio == NSSize(width: 1, height: 1)
                         && abs(squareLyricsSize.width - squareLyricsSize.height) < 1,
                         "Square paging did not keep the lyrics page square")
            await capture("square-paged-lyrics-page")
            let squareBack = press("fusionplay.player.lyrics.toggle"); await settle()
            precondition(window.contentRect(forFrameRect: window.frame).size == squareLyricsSize,
                         "Square page navigation resized the native window")
            precondition(button("fusionplay.player.lyric-summary") == nil,
                         "Square cover paging unexpectedly used the separate playback column")
            await capture("square-paged-cover-playback", action: squareBack)
            if let model, var stopped = model.snapshot {
                stopped.controlsAvailable = false; stopped.phase = .stopped; stopped.trackId = ""; stopped.title = ""; stopped.lyricsText = ""
                model.previewLyricsUpdate(stopped)
            }
            await settle()
            precondition(window.contentRect(forFrameRect: window.frame).size == squareLyricsSize,
                         "Stopping media resized square paging")
            await capture("square-paged-idle")
            defaults.set(NarrowPlayerLayout.ipadPaged.rawValue, forKey: NarrowPlayerLayout.storageKey); await settle()
            window.setContentSize(NSSize(width: 420, height: 300)); await settle()
            precondition(window.contentAspectRatio == .zero
                         && window.contentRect(forFrameRect: window.frame).size == NSSize(width: 420, height: 300),
                         "Separate playback mode retained the square constraint")
            await capture("ipad-restored-idle")
            precondition(defaults.string(forKey: "playerLyricsDisplayMode") == "never", "Page navigation rewrote the saved lyric policy")
            let report: [String: Any] = ["captures": records, "noReceiverStarted": true, "pageAction": pageAction,
                "note": "Inspect screenshots to confirm virtual AX navigation; event submission alone is not an interaction pass."]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("assembled-player-check.json"))
            print("Assembled PlayerView evidence: " + output.path); fflush(stdout)
            window.orderOut(nil); exit(0)
        }
    }
}
