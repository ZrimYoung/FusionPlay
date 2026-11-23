import AppKit
import SwiftUI

@MainActor private final class InputCounter {
    var count = 0
}
@MainActor private final class InputWitness {
    static weak var scroll: NSScrollView?
}
private struct NativeLyricsScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSScrollView {
        let view = NSScrollView()
        view.identifier = .init("input-check.lyrics")
        view.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 900))
        view.hasVerticalScroller = true
        InputWitness.scroll = view
        return view
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
private struct InputCanvas: View {
    let target: PlayerCanvasPose
    let motion: PlayerResponsiveMotionDriver
    let counter: InputCounter
    var enabled = true
    var interactive = true
    var environmentEnabled = true
    var symbol = "play.fill"
    var label = "Play"
    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerTransportButton(symbol: symbol, label: label, enabled: enabled, interactive: interactive) { counter.count += 1 }
                .disabled(!environmentEnabled)
                .canvasPlacement(.playPause, target: target, motion: motion, interactive: true)
            NativeLyricsScroller()
                .canvasPlacement(.lyrics, target: target, motion: motion, interactive: true)
        }.frame(width: 600, height: 400, alignment: .topLeading)
    }
}
@main struct PlayerCanvasInputSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        do { try check(); exit(0) }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func check() throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "PlayerCanvasInput", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        func pump(_ host: NSView) {
            let until = Date().addingTimeInterval(0.10)
            repeat {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            } while Date() < until
        }
        let counter = InputCounter()
        var time: TimeInterval = 0
        let driver = PlayerResponsiveMotionDriver(automaticallyTicks: false, now: { time })
        let initial = PlayerCanvasPose(nodes: [
            .playPause: .init(frame: CGRect(x: 50, y: 180, width: 100, height: 40)),
            .lyrics: .init(frame: CGRect(x: 350, y: 150, width: 100, height: 100))
        ])
        let key = PlayerCanvasMotionKey(compact: false, cover: false, page: .playback,
            lyrics: true, controls: true, progress: true, transport: true)
        driver.move(to: initial, key: key, animated: false)
        let host = NSHostingView(rootView: InputCanvas(target: initial, motion: driver, counter: counter))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.alphaValue = 0
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = host
        defer { window.contentView = nil; window.close(); driver.stop() }
        pump(host)
        func probe(_ element: PlayerCanvasElement) throws -> NSView {
            guard let view = descendants(host).first(where: {
                $0.identifier?.rawValue == "fusionplay.player.hit-area." + element.rawValue
            }) else { throw NSError(domain: "Missing hit probe: \(element.rawValue)", code: 1) }
            return view
        }
        var scopeChecks = 0
        func checkScope(_ pose: PlayerCanvasPose) throws {
            for role in [PlayerCanvasElement.playPause, .lyrics] {
                let view = try probe(role)
                let expected = pose[role].frame
                let actual = view.convert(view.bounds, to: host)
                // NSHostingView uses the same flipped top-left canvas coordinates.
                try require(abs(actual.minX - expected.minX) < 0.5 && abs(actual.minY - expected.minY) < 0.5
                            && abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5,
                            "\(role) hit scope \(actual) differs from role \(expected)")
                try require(actual.width < 600 && actual.height < 400,
                            "Position expanded \(role)'s hit shape into a full-canvas input overlay")
                try require(view.hitTest(view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: view.superview)) == nil,
                            "Diagnostic witness participated in input")
                scopeChecks += 1
            }
            let lyric = try probe(.lyrics).convert(try probe(.lyrics).bounds, to: host)
            let button = pose[.playPause].frame
            try require(!lyric.contains(CGPoint(x: button.midX, y: button.midY)),
                        "The lyric role claims the playback control's position")
        }
        try checkScope(initial)
        guard let button = descendants(host).compactMap({ $0 as? PlayerTransportButton.TransportButton }).first,
              let scroll = InputWitness.scroll else {
            throw NSError(domain: "Missing real native controls", code: 1)
        }
        let nativeCenter = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        let localHit = button.hitTest(button.convert(nativeCenter, to: button.superview))
        try require(localHit === button || localHit?.isDescendant(of: button) == true,
                    "The embedded native button cannot hit its own bounds")
        let scrollCenter = CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY)
        let scrollHit = scroll.hitTest(scroll.convert(scrollCenter, to: scroll.superview))
        try require(scrollHit === scroll || scrollHit?.isDescendant(of: scroll) == true,
                    "The embedded native scroll view cannot hit its own bounds")
        button.performClick(nil)
        try require(counter.count == 1, "The placed native button did not execute its real target/action")
        // Hiding the native window does not supply SwiftUI's window-event
        // routing environment. Do not call a direct action a pointer click.
        let hostPoint = button.convert(nativeCenter, to: host.superview)
        let rootHit = host.hitTest(hostPoint)
        let rootReachesButton = rootHit === button || rootHit?.isDescendant(of: button) == true
        try require(rootReachesButton, "The native hosting root did not route to the production button")
        print("INFO: offscreen hosting root reaches native button=\(rootReachesButton); this is not a system-pointer test")

        var target = initial
        target[.playPause].frame = CGRect(x: 120, y: 280, width: 62, height: 62)
        target[.lyrics].frame = CGRect(x: 280, y: 40, width: 300, height: 300)
        host.rootView = InputCanvas(target: target, motion: driver, counter: counter)
        let compactKey = PlayerCanvasMotionKey(compact: true, cover: false, page: .playback,
            lyrics: true, controls: true, progress: true, transport: true)
        driver.move(to: target, key: compactKey, animated: true)
        time = 0.08; driver.advance(to: time); pump(host)
        guard let intermediate = driver.pose else { throw NSError(domain: "Missing intermediate pose", code: 1) }
        try require(intermediate != initial && intermediate != target, "Motion never exposed a real intermediate role frame")
        try checkScope(intermediate)
        let lyricFrame = intermediate[.lyrics].frame
        let outsideLyrics = CGPoint(x: min(590, lyricFrame.maxX + 6), y: lyricFrame.midY)
        try require(!lyricFrame.contains(outsideLyrics), "Missing clipped-lyric input witness")
        let outsideHit = host.hitTest(host.convert(outsideLyrics, to: host.superview))
        try require(outsideHit !== scroll && outsideHit?.isDescendant(of: scroll) != true,
                    "Native lyric input escaped its visible interpolated role bounds")
        time = 2; driver.advance(to: time); pump(host)
        try checkScope(target)
        button.performClick(nil)
        try require(counter.count == 2, "The native action was lost after placement interpolation")
        guard let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else {
            throw NSError(domain: "No local key-method fixture", code: 1)
        }
        // Invoke this owned button's method directly; no event is posted to an
        // application, window, event tap or system queue.
        button.keyDown(with: space)
        try require(counter.count == 3, "Focused native Space handling lost the production callback")
        button.highlight(true)
        try require(button.alphaValue == 0.65, "Pressed feedback disappeared")
        button.highlight(false)
        try require(button.alphaValue == 1, "Pressed feedback did not reset")
        let oldImage = button.image
        host.rootView = InputCanvas(target: target, motion: driver, counter: counter, symbol: "pause.fill", label: "Pause")
        pump(host)
        try require(button.image != nil && button.image !== oldImage && button.accessibilityLabel() == "Pause" && button.toolTip == "Pause",
                    "Symbol/AX label/help did not update on the retained native control")
        try require(button.accessibilityIdentifier() == "fusionplay.player.transport.playPause", "Playback identity changed with its symbol")
        for state in 0..<3 {
            host.rootView = InputCanvas(target: target, motion: driver, counter: counter,
                enabled: state != 0, interactive: state != 1, environmentEnabled: state != 2)
            pump(host)
            let center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
            try require(button.hitTest(button.convert(center, to: button.superview)) == nil,
                        "Disabled/inactive/environment-disabled transport consumed pointer input")
            try require(!button.acceptsFirstResponder, "Inactive transport accepted keyboard focus")
            button.performClick(nil)
            try require(counter.count == 3, "Inactive transport dispatched an action")
        }
        host.rootView = InputCanvas(target: target, motion: driver, counter: counter)
        pump(host)
        try require(button.isEnabled && button.interactive && button.acceptsFirstResponder, "Restored transport remained disabled")
        button.performClick(nil)
        try require(counter.count == 4, "Restored native transport lost its action")
        var transparent = target
        transparent[.playPause].opacity = 0.04
        host.rootView = InputCanvas(target: transparent, motion: driver, counter: counter)
        driver.move(to: transparent, key: compactKey, animated: false)
        pump(host)
        let hiddenPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host.superview)
        let hiddenHit = host.hitTest(hiddenPoint)
        try require(hiddenHit !== button && hiddenHit?.isDescendant(of: button) != true,
                    "Nearly transparent role still consumed native hosting-root input")
        try require(!window.isVisible && window.alphaValue == 0 && NSApp.activationPolicy() == .prohibited
                    && !NSRunningApplication.current.isActive, "Input check showed or activated a window")
        print("PASS: \(scopeChecks) production local hit-scope checks; native hosting-root/clip/transparent-role hit tests, four production actions, retained symbol/AX/help, disabled/inactive/environment-disabled passthrough; no ordering, activation, system input or capture")
        print("LIMIT: Native hosting-root hit routing and owned control actions were checked; no system-pointer click or live receiver command was sent")
    }
}
