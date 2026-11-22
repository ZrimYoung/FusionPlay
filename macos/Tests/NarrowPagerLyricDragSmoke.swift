import AppKit
import SwiftUI

private final class OffscreenPagingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
private final class PagingTestRegion: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
private final class PagingAXNode: NSObject {
    @objc dynamic var accessibilityRole = NSAccessibility.Role.staticText.rawValue
    @objc dynamic var accessibilityFrame = NSRect(x: -10_000, y: -10_000, width: 20_000, height: 20_000)
    @objc dynamic var accessibilityIdentifier: String?
    @objc dynamic var accessibilityParent: NSObject?
}
private final class PagingTestRoot: NSView {
    var flippedCoordinates = false
    override var isFlipped: Bool { flippedCoordinates }
    var node: PagingAXNode?
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { node }
}
private final class PagingMouseEvent: NSEvent {
    weak var owner: NSWindow?
    var point: NSPoint = .zero
    override var type: NSEvent.EventType { .leftMouseDown }
    override var window: NSWindow? { owner }
    override var locationInWindow: NSPoint { point }
}
private final class PagingDrivenPan: NSPanGestureRecognizer {
    var offset = NSPoint.zero
    var phase: NSGestureRecognizer.State = .possible
    override var state: NSGestureRecognizer.State {
        get { phase }
        set { phase = newValue }
    }
    override func translation(in view: NSView?) -> NSPoint { offset }
}
private final class PagingWheelEvent: NSEvent {
    weak var owner: NSWindow?
    var point: NSPoint = .zero
    var x: CGFloat = 0
    var y: CGFloat = 0
    var wheelPhase: NSEvent.Phase = .began
    var momentum: NSEvent.Phase = []
    var clock: TimeInterval = 1
    override var window: NSWindow? { owner }
    override var locationInWindow: NSPoint { point }
    override var type: NSEvent.EventType { .scrollWheel }
    override var scrollingDeltaX: CGFloat { x }
    override var scrollingDeltaY: CGFloat { y }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { wheelPhase }
    override var momentumPhase: NSEvent.Phase { momentum }
    override var timestamp: TimeInterval { clock }
}

/// Exercises only this offscreen window's geometry/delegate/action methods.
/// No orderFront/orderBack, NSApplication.postEvent, system input or screenshots.
@main struct NarrowPagerLyricDragSmoke {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching()
        let window = OffscreenPagingPanel(contentRect: NSRect(x: 100, y: 100, width: 420, height: 520),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.ignoresMouseEvents = true
        let root = PagingTestRoot(frame: NSRect(x: 0, y: 0, width: 420, height: 520))
        root.flippedCoordinates = ProcessInfo.processInfo.environment["FUSIONPLAY_LYRIC_DRAG_FLIPPED"] == "1"
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 400))
        scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 1_200))
        scroll.documentView = document; root.addSubview(scroll)
        let region = PagingTestRegion(frame: root.bounds); root.addSubview(region)
        root.layoutSubtreeIfNeeded()
        let coordinator = NarrowPlayerHorizontalScroll.Coordinator()
        coordinator.view = region
        var pages: [CompactPlayerPage] = []
        coordinator.requestPage = { pages.append($0) }
        coordinator.installDrag()
        defer { coordinator.dismantle() }
        let installed = root.gestureRecognizers.compactMap { $0 as? NSPanGestureRecognizer }
            .first { $0.target === coordinator }!
        var checks = 0
        func require(_ valid: @autoclosure () -> Bool, _ message: String) {
            guard valid() else { fatalError(message) }; checks += 1
        }
        let mouse = PagingMouseEvent(); mouse.owner = window
        let rowPoint = scroll.contentView.convert(NSPoint(x: scroll.contentView.bounds.midX, y: scroll.contentView.bounds.midY), to: nil)
        mouse.point = rowPoint
        let row = PagingAXNode(); row.accessibilityRole = NSAccessibility.Role.button.rawValue
        let label = PagingAXNode(); label.accessibilityParent = row
        root.node = label
        func attempts() -> Bool { coordinator.gestureRecognizer(installed, shouldAttemptToRecognizeWith: mouse) }
        require(!attempts(), "Default behavior must preserve control/text interaction")
        coordinator.allowsLyricDragging = true
        require(attempts(), "A lyric's static-text child and button parent still reject paging")
        require(installed.delaysPrimaryMouseButtonEvents && installed.buttonMask == 1,
                "Recognized paging must retain AppKit's delayed-click cancellation")
        require(coordinator.gestureRecognizer(installed, shouldBeRequiredToFailBy: NSClickGestureRecognizer()),
                "Click recognition must wait for the paging pan to fail")
        let pan = PagingDrivenPan()
        pan.offset = .zero
        require(!coordinator.gestureRecognizerShouldBegin(pan), "A single click must fail pan recognition")
        pan.offset = NSPoint(x: 3, y: 40)
        require(!coordinator.gestureRecognizerShouldBegin(pan), "Vertical drag must remain with the lyric scroller")
        pan.offset = NSPoint(x: 36, y: 30)
        require(!coordinator.gestureRecognizerShouldBegin(pan), "Ambiguous diagonal drag must not steal scrolling")
        pan.offset = NSPoint(x: -60, y: 4)
        require(coordinator.gestureRecognizerShouldBegin(pan), "Horizontal lyric dragging never recognizes")
        func drive(_ offset: NSPoint, _ state: NSGestureRecognizer.State) {
            pan.offset = offset; pan.phase = state
            coordinator.perform(NSSelectorFromString("didDrag:"), with: pan)
        }
        drive(NSPoint(x: -10, y: 1), .began)
        require(pages.isEmpty, "A small drag must not page")
        drive(NSPoint(x: -60, y: 3), .changed)
        drive(NSPoint(x: -130, y: 4), .changed)
        drive(NSPoint(x: -160, y: 4), .ended)
        require(pages == [.lyrics], "One drag must turn exactly one page")
        require(attempts(), "A second lyric drag was not accepted")
        drive(NSPoint(x: 60, y: 2), .began)
        require(pages == [.lyrics, .playback], "Dragging right must return to playback")

        for role in [NSAccessibility.Role.slider, .textField, .textArea, .link, .scrollBar, .popUpButton, .menuButton, .splitter] {
            label.accessibilityRole = role.rawValue
            require(!attempts(), "A real control role was swallowed: " + role.rawValue)
        }
        label.accessibilityRole = NSAccessibility.Role.staticText.rawValue
        for identifier in ["fusionplay.player.progress", "fusionplay.player.paged-progress", "fusionplay.player.cover-lyrics-resize"] {
            label.accessibilityIdentifier = identifier
            require(!attempts(), "A protected progress/resize control started a page drag")
        }
        label.accessibilityIdentifier = nil
        mouse.point = root.convert(NSPoint(x: 100, y: root.isFlipped ? 20 : root.bounds.maxY - 20), to: nil)
        require(!attempts(), "Native titlebar must remain available for dragging the window")
        mouse.point = root.convert(NSPoint(x: 100, y: 450), to: nil)
        require(!attempts(), "A header button outside the lyric scroller must stay interactive")
        root.node = label; label.accessibilityParent = nil
        require(attempts(), "Empty lyric-state labels should not prevent paging back")
        mouse.point = rowPoint; label.accessibilityParent = row
        let exclusion = PlayerPagingDragExclusion.Region(frame: root.convert(NSRect(x: rowPoint.x - 10, y: rowPoint.y - 10, width: 20, height: 20), from: nil))
        root.addSubview(exclusion)
        require(!attempts(), "Native drag exclusion must win without relying on accessibility")
        exclusion.removeFromSuperview()
        let control = NSButton(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
        control.setFrameOrigin(document.convert(rowPoint, from: nil))
        document.addSubview(control)
        mouse.point = control.convert(NSPoint(x: 20, y: 15), to: nil)
        require(!attempts(), "A native button inside the scroller must retain its mouse events")
        control.removeFromSuperview()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 35))
        text.isEditable = false; text.isSelectable = true
        text.setFrameOrigin(document.convert(rowPoint, from: nil)); document.addSubview(text)
        mouse.point = text.convert(NSPoint(x: 20, y: 15), to: nil)
        require(!attempts(), "Selectable native text must retain text selection")
        text.removeFromSuperview()
        mouse.point = rowPoint
        coordinator.setEnabled(false)
        require(!attempts() && !coordinator.gestureRecognizerShouldBegin(pan), "Disabled paging must not accept drags")
        coordinator.setEnabled(true)

        pages.removeAll()
        let wheel = PagingWheelEvent(); wheel.owner = window; wheel.point = rowPoint
        wheel.x = -40; wheel.y = 0; wheel.wheelPhase = .began
        require(coordinator.handleWheel(wheel) && pages == [.lyrics], "Trackpad horizontal paging regressed")
        wheel.x = 0; wheel.y = 20; wheel.wheelPhase = .ended; wheel.clock += 0.1
        require(coordinator.handleWheel(wheel) && pages.count == 1, "A horizontal stream must turn once")
        wheel.wheelPhase = []; wheel.momentum = .changed; wheel.clock += 0.1
        require(coordinator.handleWheel(wheel) && pages.count == 1, "Horizontal momentum must not turn another page")
        wheel.momentum = .ended; wheel.clock += 0.1
        _ = coordinator.handleWheel(wheel)
        wheel.momentum = []; wheel.wheelPhase = .began; wheel.x = 0; wheel.y = 50; wheel.clock += 1
        require(!coordinator.handleWheel(wheel) && pages.count == 1, "Trackpad vertical scrolling must not be consumed")
        coordinator.dismantle()
        require(!root.gestureRecognizers.contains { $0.target === coordinator }, "Paging recognizer leaked after dismantle")
        require(!window.isVisible && app.keyWindow == nil && app.mainWindow == nil,
                "Offscreen regression test ordered or activated a window")
        print("PASS: flipped=\(root.isFlipped), \(checks) offscreen lyric-drag/control/axis/trackpad checks; native delayed-click and click-failure contracts verified; no window ordering, system input or screenshots")
    }
}
