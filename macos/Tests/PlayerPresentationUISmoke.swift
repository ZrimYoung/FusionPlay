import AppKit
import SwiftUI

@MainActor private final class PagerFixture: ObservableObject {
    @Published var page = CompactPlayerPage.playback
    @Published var pagingEnabled = true
    var playbackAppeared = 0
    var lyricsAppeared = 0
    @Published var slider = 0.5
    var presses = 0
}

private struct PagerFixtureView: View {
    @ObservedObject var fixture: PagerFixture
    var body: some View {
        PlayerNarrowPager(selection: $fixture.page, requestPage: { fixture.page = $0 },
                          pagingEnabled: fixture.pagingEnabled) {
            VStack {
                Image(systemName: "music.note").font(.system(size: 64))
                Text("Playback page").font(.title2)
                Button("Test button") { fixture.presses += 1 }
                    .accessibilityIdentifier("pager-test.button")
                    .background { PlayerPagingDragExclusion(identifier: "pager-test.button-region") }
                Slider(value: $fixture.slider)
                    .frame(width: 160).accessibilityIdentifier("fusionplay.player.progress")
                    .background { PlayerPagingDragExclusion(identifier: "pager-test.progress-region") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.indigo.opacity(0.7))
                .onAppear { fixture.playbackAppeared += 1 }
        } lyrics: {
            VStack {
                Image(systemName: "quote.bubble").font(.system(size: 40))
                Text("Lyrics page\n歌词页面").font(.title2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.teal.opacity(0.7))
                .onAppear { fixture.lyricsAppeared += 1 }
        }
    }
}

private final class RoutedWheelEvent: NSEvent {
    let target: NSWindow
    let point: NSPoint
    let backing: CGEvent
    let precise: Bool
    let eventPhase: NSEvent.Phase
    init(window: NSWindow, point: NSPoint, x: Int32, y: Int32, precise: Bool, phase: NSEvent.Phase) {
        target = window; self.point = point; self.precise = precise; eventPhase = phase
        backing = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                          wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
        backing.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        backing.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        super.init()
    }
    required init?(coder: NSCoder) { failCheck("Not used") }
    override var cgEvent: CGEvent? { backing }
    override var type: NSEvent.EventType { .scrollWheel }
    override var window: NSWindow? { target }
    override var windowNumber: Int { target.windowNumber }
    override var locationInWindow: NSPoint { point }
    override var scrollingDeltaX: CGFloat { CGFloat(backing.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)) }
    override var scrollingDeltaY: CGFloat { CGFloat(backing.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)) }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { eventPhase }
    override var momentumPhase: NSEvent.Phase { [] }
    override var timestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@main struct PlayerPresentationUISmoke {
    @MainActor static func main() throws {
        requireCheck(Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.presentation-check")
        let interactive = ProcessInfo.processInfo.environment["FUSIONPLAY_UI_INTERACTIVE"] == "1"
        let app = NSApplication.shared; app.setActivationPolicy(interactive ? .accessory : .prohibited)
        app.finishLaunching()
        if !interactive { app.setActivationPolicy(.prohibited) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let typography = AppTypography()
        let titles = [("en", "A long song title that can use several readable lines without truncating every phrase",
                       "A long artist name and an equally long album title for the metadata preview"),
                      ("zh", "这是一个比较长的歌曲名称，用来检查窄窗中的换行和信息高度过渡",
                       "这是比较长的艺人名称 · 这也是比较长的专辑名称")]
        var count = 0
        func save<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
            let host = NSHostingView(rootView: view.appTypography().padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(.white).background(Color.black).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.alphaValue = 0; if interactive { window.orderBack(nil) }
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { failCheck("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            window.contentView = nil; window.close(); count += 1
        }
        for (language, title, subtitle) in titles {
            for width in [260.0, 420.0] {
                for wraps in [false, true] {
                    UserDefaults.standard.setVolatileDomain(["wrapPlayerMetadata": wraps], forName: UserDefaults.argumentDomain)
                    let height = PlayerTrackMetadataView.height(title: title, subtitle: subtitle, width: width - 32,
                        titleFont: typography.nsFont(size: 19, weight: .semibold), subtitleFont: typography.nsFont(size: 12),
                        spacing: 5, wraps: wraps, defaultTitleLines: 2)
                    requireCheck(height > 0 && height < 180, "Metadata consumed the entire minimum-size player")
                    try save(PlayerTrackMetadataView(title: title, subtitle: subtitle, width: width - 32,
                        titleSize: 19, subtitleSize: 12, spacing: 5, defaultTitleLines: 2),
                        width: width, height: 200, name: "metadata-\(language)-\(Int(width))-\(wraps ? "wrap" : "plain")")
                }
            }
        }
        let fixture = PagerFixture()
        let host = NSHostingView(rootView: PagerFixtureView(fixture: fixture).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.alphaValue = 0; if interactive { window.orderBack(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        requireCheck(fixture.playbackAppeared <= 1 && fixture.lyricsAppeared <= 1)
        for page in [CompactPlayerPage.playback, .lyrics, .playback] {
            fixture.page = page
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            requireCheck(fixture.playbackAppeared <= 1 && fixture.lyricsAppeared <= 1,
                         "Page navigation recreated an existing lyric or playback subtree")
            requireCheck(host.bounds.size == NSSize(width: 320, height: 300))
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { failCheck("No pager bitmap") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("pager-" + page.rawValue + ".png"))
        }
        // Drive the production wheel handler and AppKit mouse event queue,
        // rather than changing selection directly. Synthetic CG wheel events
        // do not carry a target window through NSApplication.postEvent.
        func pump(_ seconds: TimeInterval = 0.12) {
            let deadline = Date().addingTimeInterval(seconds)
            repeat {
                if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01),
                                             inMode: .default, dequeue: true) { app.sendEvent(event) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            } while Date() < deadline
        }
        window.isMovableByWindowBackground = true
        window.alphaValue = interactive ? 1 : 0
        if let visible = NSScreen.main?.visibleFrame { window.setFrameOrigin(NSPoint(x: visible.midX - 160, y: visible.midY - 150)) }
        if interactive {
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        pump()
        @discardableResult func wheel(x: Int32, y: Int32, precise: Bool = true, phase: NSEvent.Phase = .began) -> Bool {
            let coordinator = host.gestureRecognizers.compactMap { $0.target as? NarrowPlayerHorizontalScroll.Coordinator }.first!
            return coordinator.handleWheel(RoutedWheelEvent(window: window, point: NSPoint(x: 160, y: 170),
                                                         x: x, y: y, precise: precise, phase: phase))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        guard let region = descendants(host).first(where: { $0.identifier?.rawValue == "fusionplay.player.horizontal-paging-region" }) else {
            failCheck("No mounted paging region in the offscreen view")
        }
        requireCheck(region.bounds.size == NSSize(width: 320, height: 300),
                     "The paging hit region followed the translated two-page strip")
        fixture.page = .playback; pump(0.35)
        wheel(x: -40, y: 0)
        pump(0.35)
        requireCheck(fixture.page == .lyrics, "Precise trackpad input did not reach the pager")
        wheel(x: 40, y: 0)
        pump(0.35)
        requireCheck(fixture.page == .playback, "The transformed lyrics page could not page back")
        wheel(x: -4, y: 0, precise: false)
        pump(0.35)
        requireCheck(fixture.page == .lyrics, "Ordinary horizontal mouse wheel was ignored")
        wheel(x: 0, y: 50)
        pump(0.35)
        requireCheck(fixture.page == .lyrics, "Vertical scrolling changed pages")
        fixture.page = .playback; pump(0.35)
        func mouse(_ kind: NSEvent.EventType, at point: NSPoint, number: Int) {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: number, clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1)!
            app.postEvent(event, atStart: false)
        }
        if interactive {
        let initialFrame = window.frame
        func drag(from start: NSPoint, to end: NSPoint) {
            mouse(.leftMouseDown, at: start, number: 1)
            for step in 1...12 {
                let fraction = CGFloat(step) / 12
                mouse(.leftMouseDragged, at: NSPoint(x: start.x + (end.x - start.x) * fraction,
                                                     y: start.y + (end.y - start.y) * fraction), number: step + 1)
            }
            mouse(.leftMouseUp, at: end, number: 14)
            pump(0.4)
        }
        // Artwork drags must flip rather than move a background-draggable window.
        drag(from: NSPoint(x: 240, y: 220), to: NSPoint(x: 96, y: 220))
        requireCheck(fixture.page == .lyrics, "A horizontal artwork mouse drag could not turn the square page")
        requireCheck(window.frame == initialFrame, "Paging dragged the native window instead")
        drag(from: NSPoint(x: 70, y: 220), to: NSPoint(x: 214, y: 220))
        requireCheck(fixture.page == .playback && window.frame == initialFrame,
                     "Dragging back failed or moved the native window")
        let regions = descendants(host)
        guard let button = regions.first(where: { $0.identifier?.rawValue == "pager-test.button-region" }),
              let slider = regions.first(where: { $0.identifier?.rawValue == "pager-test.progress-region" }) else {
            failCheck("Expected native control priority regions without an accessibility client")
        }
        let buttonFrame = button.convert(button.bounds, to: nil)
        let buttonPoint = NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        mouse(.leftMouseDown, at: buttonPoint, number: 1)
        mouse(.leftMouseUp, at: buttonPoint, number: 2); pump()
        requireCheck(fixture.presses == 1 && fixture.page == .playback,
                     "Paging intercepted the native playback button")
        let sliderFrame = slider.convert(slider.bounds, to: nil)
        let before = fixture.slider
        drag(from: NSPoint(x: sliderFrame.midX, y: sliderFrame.midY),
             to: NSPoint(x: sliderFrame.maxX - 8, y: sliderFrame.midY))
        requireCheck(fixture.slider > before && fixture.page == .playback && window.frame == initialFrame,
                     "A progress drag was stolen by paging or window dragging")
        fixture.pagingEnabled = false; pump()
        requireCheck(!wheel(x: -40, y: 0), "A disabled pager consumed horizontal wheel input")
        pump()
        requireCheck(fixture.page == .playback, "Disabled wheel input changed the page")
        window.isMovableByWindowBackground = false
        drag(from: NSPoint(x: 240, y: 220), to: NSPoint(x: 96, y: 220))
        requireCheck(fixture.page == .playback, "A disabled pager captured a mouse drag")
        fixture.pagingEnabled = true; window.isMovableByWindowBackground = true; pump()
        drag(from: NSPoint(x: 240, y: 220), to: NSPoint(x: 96, y: 220))
        requireCheck(fixture.page == .lyrics && window.frame == initialFrame,
                     "Reenabled paging did not recover its original native input path")
        requireCheck(fixture.playbackAppeared <= 1 && fixture.lyricsAppeared <= 1,
                     "Input navigation recreated the mounted playback or lyric subtree")
        }
        if !interactive {
            requireCheck(window.alphaValue == 0 && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(),
                         "Silent presentation check showed its window or took foreground focus")
        }
        window.contentView = nil; window.close()
        print(interactive
            ? "PASS: \(count) metadata snapshots, pager policies and native pointer ownership"
            : "PASS: \(count) offscreen metadata snapshots and pager policies; no window ordering or focus changes; native pointer checks are opt-in")
    }
}

private func requireCheck(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "Check failed") {
    if !condition() { failCheck(message()) }
}
private func failCheck(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
    exit(1)
}
