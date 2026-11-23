import AppKit
import SwiftUI

private final class ResizeWindow: NSWindow {
    var fullScreenState = false
    var inspectNativeEdges = false
    var nativeDowns = 0
    override var styleMask: NSWindow.StyleMask {
        get { fullScreenState ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }
    override func sendEvent(_ event: NSEvent) {
        if inspectNativeEdges && [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            if event.type == .leftMouseDown { nativeDowns += 1 }
            return
        }
        super.sendEvent(event)
    }
}
private final class ClickTarget: NSObject {
    var count = 0
    @objc func clicked() { count += 1 }
}

@main struct CoverLyricsResizeSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in await check(); exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { exit(124) }
        app.run()
    }
    @MainActor static func check() async {
        let window = ResizeWindow(contentRect: NSRect(x: 100, y: 300, width: 360, height: 360),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
        window.contentView = content
        let attachment = PlayerWindowBehavior.WindowAttachmentView()
        let policy = PlayerWindowBehavior.Coordinator()
        content.addSubview(attachment)
        let grip = CoverLyricsResizeGrip(frame: NSRect(x: 0, y: 0, width: 360, height: 14))
        content.addSubview(grip)
        var expanded = false, dragging = false, hasTrack = true
        var changes: [Bool] = []
        func apply() {
            policy.update(attachment, policy: PlayerWindowBehavior(square: !expanded, miniRequest: 0,
                miniLyrics: expanded, dimButtons: false, pinned: true, duration: 0,
                layoutMode: expanded ? .original : .squarePaged, coverLyricsResizing: dragging, hasTrack: hasTrack))
        }
        func pause(_ seconds: Double = 0.05) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func size() -> NSSize { window.contentRect(forFrameRect: window.frame).size }
        func near(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
            precondition(abs(actual - expected) < 0.5, "\(message): \(actual) != \(expected)")
        }
        grip.onDraggingChanged = { dragging = $0; apply() }
        grip.onExpansionChanged = { expanded = $0; changes.append($0); apply() }
        apply(); await pause()
        window.orderFront(nil)
        let top = window.frame.maxY, left = window.frame.minX
        func post(_ type: NSEvent.EventType, screen: NSPoint, withoutWindow: Bool = false) {
            let location = withoutWindow ? screen : window.convertPoint(fromScreen: screen)
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: withoutWindow ? 0 : window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            if withoutWindow { precondition(event.window == nil, "Outside-pointer fixture retained a window") }
            NSApp.postEvent(event, atStart: false)
        }
        func drag(edgeOffset: CGFloat, delta: CGFloat, outside: Bool = false,
                  during: (() async -> Void)? = nil) async {
            let point = NSPoint(x: window.frame.midX, y: window.frame.minY + edgeOffset)
            let end = NSPoint(x: point.x, y: point.y + delta)
            post(.leftMouseDown, screen: point); await pause()
            post(.leftMouseDragged, screen: end, withoutWindow: outside); await pause()
            await during?()
            post(.leftMouseUp, screen: end, withoutWindow: outside); await pause(0.32)
        }
        // Inspection is downstream of all real local monitors. An unclaimed
        // border down reaches NSWindow, which this fixture counts instead of
        // entering AppKit's modal native resize loop in an unattended test.
        window.inspectNativeEdges = true
        await drag(edgeOffset: -2, delta: -80, outside: true) {
            precondition(expanded && dragging, "The real outside bottom edge did not claim the pointer")
            near(size().height, 440, "Square aspect stole bottom-edge expansion")
            precondition(window.contentAspectRatio == .zero && window.level == .floating)
            apply(); await pause(); near(size().height, 440, "Snapshot update stole active edge geometry")
        }
        precondition(window.nativeDowns == 0, "Bottom-border down leaked to native window resizing")
        precondition(expanded && !dragging)
        near(size().height, 496, "Open snap did not settle to the minimum pane")
        near(window.frame.maxY, top, "Opening moved the top edge")
        near(window.frame.minX, left, "Opening moved the left edge")
        near(size().width, 360, "Opening changed cover width")

        await drag(edgeOffset: 2, delta: -84)
        near(size().height, 580, "Inside bottom edge lost the chosen pane height")
        await drag(edgeOffset: -2, delta: 200, outside: true) {
            precondition(expanded && dragging)
            near(size().height, 380, "Pane did not shrink continuously to a sliver")
        }
        precondition(!expanded && !dragging, "Sliver failed to snap closed after the animation")
        near(size().height, 360, "Collapse did not finish at a physical square")
        precondition(window.contentAspectRatio == NSSize(width: 1, height: 1))
        near(window.frame.maxY, top, "Closing moved the top edge")
        await drag(edgeOffset: -2, delta: -180, outside: true)
        precondition(expanded && !dragging, "Bottom edge could not reopen after collapsing")
        near(size().height, 540, "Reopening used a stale pointer frame")

        // Reverse a collapse while its frame animation is still running.
        // The old animator must stop writing frames, not merely ignore its callback.
        let collapseStart = NSPoint(x: window.frame.midX, y: window.frame.minY - 2)
        post(.leftMouseDown, screen: collapseStart); await pause()
        let nearClosed = NSPoint(x: collapseStart.x, y: collapseStart.y + size().height - size().width - 30)
        post(.leftMouseDragged, screen: nearClosed, withoutWindow: true); await pause()
        post(.leftMouseUp, screen: nearClosed, withoutWindow: true); await pause(0.04)
        let reverseStart = NSPoint(x: window.frame.midX, y: window.frame.minY - 2)
        let reverseHeight = size().height + 170
        post(.leftMouseDown, screen: reverseStart); await pause(0.01)
        let reverseEnd = NSPoint(x: reverseStart.x, y: reverseStart.y - 170)
        post(.leftMouseDragged, screen: reverseEnd, withoutWindow: true); await pause(0.28)
        precondition(expanded && dragging, "Interrupted collapse released the new pointer ownership")
        near(size().height, reverseHeight, "The old frame animation overwrote the reverse drag")
        post(.leftMouseUp, screen: reverseEnd, withoutWindow: true); await pause(0.32)
        precondition(expanded && !dragging, "A reverse drag ended in the stale closed mode")

        let frame = window.frame
        let otherEdges = [NSPoint(x: frame.midX, y: frame.maxY - 2),
            NSPoint(x: frame.minX + 2, y: frame.midY), NSPoint(x: frame.maxX - 2, y: frame.midY),
            NSPoint(x: frame.minX + 2, y: frame.minY + 2), NSPoint(x: frame.maxX - 2, y: frame.minY - 2)]
        let beforeDowns = window.nativeDowns
        for point in otherEdges {
            post(.leftMouseDown, screen: point); post(.leftMouseUp, screen: point); await pause()
        }
        precondition(window.nativeDowns == beforeDowns + otherEdges.count,
                     "Top/side/corner resize was intercepted by the bottom-edge monitor")
        precondition(expanded && !dragging && window.frame == frame)
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        window.setContentSize(NSSize(width: 360, height: 400))
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        await pause()
        precondition(expanded && !dragging, "A native top resize incorrectly collapsed pane mode")

        window.inspectNativeEdges = false
        let click = ClickTarget()
        let button = NSButton(frame: NSRect(x: 50, y: 80, width: 100, height: 28))
        button.title = "Preview control"; button.target = click; button.action = #selector(ClickTarget.clicked)
        content.addSubview(button)
        let point = window.convertPoint(toScreen: NSPoint(x: 90, y: 94))
        post(.leftMouseDown, screen: point); post(.leftMouseUp, screen: point); await pause()
        precondition(click.count == 1 && !dragging, "Bottom monitor intercepted an ordinary control")

        let snapStart = NSPoint(x: window.frame.midX, y: window.frame.minY - 2)
        post(.leftMouseDown, screen: snapStart); await pause()
        let snapEnd = NSPoint(x: snapStart.x, y: snapStart.y + size().height - size().width - 25)
        post(.leftMouseDragged, screen: snapEnd, withoutWindow: true); await pause()
        post(.leftMouseUp, screen: snapEnd, withoutWindow: true); await pause(0.04)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        let beforeFullScreen = window.frame
        window.fullScreenState = true
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        apply(); await pause(0.3)
        precondition(window.frame == beforeFullScreen, "A cancelled snap kept animating into full screen")
        window.inspectNativeEdges = true
        await drag(edgeOffset: -2, delta: -80)
        precondition(window.frame == beforeFullScreen && !dragging,
                     "Bottom monitor resized a full-screen window")
        precondition(!grip.accessibilityPerformIncrement() && !grip.accessibilityPerformDecrement())
        window.fullScreenState = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        apply(); await pause()
        precondition(grip.accessibilityPerformDecrement())
        await pause(0.04)
        hasTrack = false; apply()
        grip.removeFromSuperview()
        let afterDetach = window.frame
        await pause(0.32)
        precondition(!dragging && window.frame == afterDetach,
                     "A detached grip kept its old animation or geometry ownership")
        let downsAfterDetach = window.nativeDowns
        let detachedPoint = NSPoint(x: window.frame.midX, y: window.frame.minY - 2)
        post(.leftMouseDown, screen: detachedPoint); post(.leftMouseUp, screen: detachedPoint); await pause()
        precondition(window.nativeDowns == downsAfterDetach + 1,
                     "A detached grip retained its local mouse monitor")
        grip.invalidate(); policy.dismantle(); window.close()
        print("PASS: actual bottom border +/-2pt, square-aspect override, windowless outside drag/up, animated sliver snap, reopen and mid-snap reversal, top/side/corner pass-through, native-top exclusion, controls, fullscreen and detach cancellation/monitor cleanup")
    }
}
