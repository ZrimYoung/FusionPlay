import AppKit
import QuartzCore

@main struct CoverLyricsIndicatorSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in await check(); exit(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { exit(124) }
        app.run()
    }
    @MainActor static func check() async {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 300, width: 360, height: 360),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 360))
        let grip = CoverLyricsResizeGrip(frame: NSRect(x: 0, y: 0, width: 360, height: 14))
        content.addSubview(grip); window.contentView = content
        grip.testIndicatorReduceMotion = false
        window.orderFront(nil); content.layoutSubtreeIfNeeded()
        guard let indicator = grip.layer?.sublayers?.first(where: { $0.name == "fusionplay.cover-lyrics-grip-indicator" }) else {
            preconditionFailure("Native grip has no independent indicator layer")
        }
        var ownership: [Bool] = []
        grip.onDraggingChanged = { ownership.append($0) }
        func pause(_ value: Double) async { try? await Task.sleep(nanoseconds: UInt64(value * 1_000_000_000)) }
        func opacity() -> Float { indicator.presentation()?.opacity ?? indicator.opacity }
        func event(_ type: NSEvent.EventType = .mouseMoved, x: CGFloat = 180, y: CGFloat = 7) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        func clearAnimation() -> Bool { indicator.animationKeys()?.isEmpty ?? true }
        await pause(0.08)
        precondition(opacity() == 0 && clearAnimation())
        let originalBounds = grip.bounds
        grip.mouseEntered(with: event()); await pause(0.07)
        let fadeIn = opacity()
        precondition(fadeIn > 0.005 && fadeIn < 0.295, "Hover indicator appeared without an intermediate fade: \(fadeIn)")
        await pause(0.22)
        precondition(abs(opacity() - 0.3) < 0.01 && indicator.opacity == 0.3,
                     "Hover fade did not settle at its visible opacity")
        grip.mouseExited(with: event()); await pause(0.12)
        let fadeOut = opacity()
        precondition(fadeOut > 0.01 && fadeOut < 0.3, "Pointer-out did not fade gradually: \(fadeOut)")
        grip.mouseEntered(with: event())
        let reversal = indicator.animation(forKey: "grip-opacity") as? CABasicAnimation
        let reversalStart = (reversal?.fromValue as? NSNumber)?.floatValue ?? -1
        precondition(abs(reversalStart - fadeOut) < 0.03, "Interrupted fade jumped instead of resuming from presentation opacity")
        await pause(0.25)
        precondition(abs(opacity() - 0.3) < 0.01)
        precondition(grip.bounds == originalBounds, "Indicator animation changed the edge hit area")

        grip.mouseDown(with: event(.leftMouseDown))
        grip.mouseDragged(with: event(.leftMouseDragged, y: -23))
        grip.mouseExited(with: event())
        await pause(0.25)
        precondition(abs(opacity() - 0.7) < 0.01 && ownership == [true],
                     "Pointer-out hid the indicator during a claimed edge drag")
        grip.mouseUp(with: event(.leftMouseUp, y: -23))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            await pause(0.07)
            precondition(abs(opacity() - 0.7) < 0.01 && ownership == [true],
                         "Indicator faded before the native snap completed")
        }
        await pause(0.27)
        precondition(ownership == [true, false])
        let afterSnap = opacity()
        precondition(afterSnap > 0 && afterSnap < 0.7, "Snap completion did not begin a gradual fade-out")
        await pause(0.42)
        precondition(opacity() < 0.01 && indicator.opacity == 0)

        grip.testIndicatorReduceMotion = true
        grip.mouseEntered(with: event())
        precondition(indicator.opacity == 0.3 && clearAnimation(), "Reduce Motion still animated hover")
        grip.mouseExited(with: event())
        precondition(indicator.opacity == 0 && clearAnimation(), "Reduce Motion still animated pointer-out")
        grip.testIndicatorReduceMotion = false
        grip.mouseEntered(with: event()); await pause(0.05)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        precondition(indicator.opacity == 0 && clearAnimation(), "Fullscreen left an indicator animation running")
        await pause(0.25)
        precondition(opacity() < 0.01)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        grip.mouseEntered(with: event()); await pause(0.05)
        grip.removeFromSuperview()
        precondition(indicator.opacity == 0 && clearAnimation(), "Detach retained its hover animation")
        await pause(0.25)
        precondition(opacity() < 0.01)
        window.close()
        print("PASS: independent indicator opacity has intermediate/end states, slower exit, smooth reversal, drag/snap visibility, unchanged hit bounds, Reduce Motion and fullscreen/detach cleanup")
    }
}
