import AppKit
import SwiftUI

/// Simulate AppKit's full-screen state without creating a Space or switching
/// the user's desktop. Notifications still exercise the production observers.
private final class FullScreenTestWindow: NSWindow {
    var simulatedFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { simulatedFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }
}

@main struct WindowBehaviorSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = FullScreenTestWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.collectionBehavior = [.auxiliary, .fullScreenNone]
        let coordinator = PlayerWindowBehavior.Coordinator()
        let view = PlayerWindowBehavior.WindowAttachmentView()
        view.coordinator = coordinator
        window.contentView = view
        window.orderBack(nil)
        func apply(square: Bool, request: Int = 0, lyrics: Bool = false, pinned: Bool = false) {
            coordinator.update(view, policy: PlayerWindowBehavior(square: square, miniRequest: request,
                miniLyrics: lyrics, dimButtons: false, pinned: pinned, duration: 0))
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.06)) }
        func contentSize() -> NSSize { window.contentRect(forFrameRect: window.frame).size }
        func assertFree() {
            precondition(window.aspectRatio == .zero && window.contentAspectRatio == .zero,
                         "Stale native aspect constraints still lock the player")
            precondition(window.resizeIncrements == NSSize(width: 1, height: 1) &&
                         window.contentResizeIncrements == NSSize(width: 1, height: 1))
        }
        // A newer large-window geometry must supersede an already queued mini update.
        window.aspectRatio = NSSize(width: 1, height: 1)
        window.contentAspectRatio = NSSize(width: 1, height: 1)
        apply(square: true); apply(square: false); settle(); assertFree()
        precondition(abs(contentSize().width - 760) < 1 && abs(contentSize().height - 400) < 1)
        precondition(app.activationPolicy() == .accessory)
        precondition(window.collectionBehavior.contains([.primary, .fullScreenPrimary]),
                     "A Dock-hidden player must opt into primary full-screen behavior")
        precondition(window.collectionBehavior.intersection([.auxiliary, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenNone]).isEmpty)
        precondition(window.standardWindowButton(.zoomButton)?.isEnabled == true)

        apply(square: false, request: 1); settle()
        precondition(window.contentAspectRatio == NSSize(width: 1, height: 1))
        precondition(abs(contentSize().width - contentSize().height) < 1)
        // Enabling lyrics on the square mini expands once into a portrait.
        apply(square: false, request: 1, lyrics: true); settle(); assertFree()
        precondition(contentSize().height > contentSize().width && window.contentMinSize.height == contentSize().width + 136)
        // Subsequent updates must retain a manually chosen portrait size.
        window.setContentSize(NSSize(width: 360, height: 620))
        apply(square: false, request: 1, lyrics: true, pinned: true); settle(); assertFree()
        precondition(window.level == .floating && abs(contentSize().height - 620) < 1)
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(contentSize().height > contentSize().width)

        apply(square: true, request: 2); settle()
        precondition(window.contentAspectRatio == NSSize(width: 1, height: 1))
        window.setContentSize(NSSize(width: 640, height: 640))
        apply(square: false, request: 2); settle(); assertFree()
        window.setContentSize(NSSize(width: 840, height: 430))
        apply(square: false, request: 2); settle(); assertFree()
        precondition(abs(contentSize().width - 840) < 1 && abs(contentSize().height - 430) < 1,
                     "Normal updates resized a freely resizable player")
        precondition(window.level == .normal && window.contentMinSize.height == 260)
        // Lyrics enabled on the expanded player must not force a portrait layout.
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(abs(contentSize().width - 840) < 1 && abs(contentSize().height - 430) < 1)
        window.setContentSize(NSSize(width: 840, height: 300))
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(abs(contentSize().width - 840) < 1 && abs(contentSize().height - 300) < 1,
                     "A wide short player unexpectedly became a portrait mini")
        window.setContentSize(NSSize(width: 840, height: 800))
        apply(square: false, request: 2, lyrics: true); settle()
        window.setContentSize(NSSize(width: 590, height: 800))
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(abs(contentSize().width - 590) < 1 && abs(contentSize().height - 800) < 1,
                     "Crossing the mini boundary unexpectedly replaced a valid user height")
        precondition(window.contentMinSize.height == 726, "Lyrics minimum did not track cover width")
        window.setContentSize(NSSize(width: 590, height: 400))
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(abs(contentSize().height - 726) < 1,
                     "Short lyrics window must grow only enough to fit square cover plus lyric pane")
        // A stopped/empty SwiftUI update can recreate native style/constraints.
        // Repair actual native state even when the desired policy is unchanged.
        window.styleMask.remove(.resizable)
        window.contentAspectRatio = NSSize(width: 1, height: 1)
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(window.styleMask.contains(.resizable))
        coordinator.dismantle()
        // A new coordinator represents a restored cold-launch window: lyrics
        // already enabled must preserve its size rather than select a new one.
        window.setContentSize(NSSize(width: 360, height: 500))
        let restoredCoordinator = PlayerWindowBehavior.Coordinator()
        view.coordinator = restoredCoordinator
        restoredCoordinator.update(view, policy: PlayerWindowBehavior(square: false, miniRequest: 0,
            miniLyrics: true, dimButtons: false, pinned: false, duration: 0))
        settle(); assertFree()
        precondition(abs(contentSize().width - 360) < 1 && abs(contentSize().height - 500) < 1,
                     "Cold-launch lyrics changed the restored window height")
        precondition(window.contentMinSize.height == 496)
        window.setContentSize(NSSize(width: 365, height: 440))
        restoredCoordinator.update(view, policy: PlayerWindowBehavior(square: false, miniRequest: 0,
            miniLyrics: true, dimButtons: false, pinned: false, duration: 0))
        settle(); assertFree()
        precondition(abs(contentSize().width - 365) < 1 && abs(contentSize().height - 501) < 1,
                     "Undersized portrait must clamp to width+136, not a square or preferred aspect")
        restoredCoordinator.dismantle()

        let fullScreenCoordinator = PlayerWindowBehavior.Coordinator()
        view.coordinator = fullScreenCoordinator
        func fullScreenPolicy(square: Bool, lyrics: Bool, pinned: Bool = true, request: Int = 0) {
            fullScreenCoordinator.update(view, policy: PlayerWindowBehavior(square: square, miniRequest: request,
                miniLyrics: lyrics, dimButtons: false, pinned: pinned, duration: 0))
        }
        func fullScreenEvent(_ name: Notification.Name) {
            NotificationCenter.default.post(name: name, object: window)
        }
        window.setContentSize(NSSize(width: 420, height: 420))
        fullScreenPolicy(square: true, lyrics: false); settle()
        precondition(window.level == .floating && window.contentAspectRatio == NSSize(width: 1, height: 1))
        fullScreenEvent(NSWindow.willEnterFullScreenNotification)
        precondition(window.level == .normal); assertFree()
        window.setContentSize(NSSize(width: 1440, height: 900))
        // A queued SwiftUI mini policy must not square the entering window.
        fullScreenPolicy(square: true, lyrics: false); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 1440, height: 900))
        window.simulatedFullScreen = true
        fullScreenEvent(NSWindow.didEnterFullScreenNotification)
        fullScreenPolicy(square: true, lyrics: true); settle(); assertFree()
        precondition(window.level == .normal && contentSize() == NSSize(width: 1440, height: 900))
        // Lyric changes during full screen must not alter native minimum size.
        precondition(window.contentMinSize == NSSize(width: 260, height: 260))
        fullScreenPolicy(square: false, lyrics: false); settle()
        fullScreenEvent(NSWindow.willExitFullScreenNotification)
        window.simulatedFullScreen = false
        window.setContentSize(NSSize(width: 420, height: 420))
        fullScreenPolicy(square: false, lyrics: false); settle(); assertFree()
        precondition(window.level == .normal && contentSize() == NSSize(width: 420, height: 420))
        fullScreenEvent(NSWindow.didExitFullScreenNotification); settle()
        precondition(window.level == .floating && contentSize() == NSSize(width: 420, height: 420))
        precondition(window.contentAspectRatio == NSSize(width: 1, height: 1),
                     "Native restored mini geometry must override stale full-screen SwiftUI width")

        fullScreenPolicy(square: false, lyrics: true); settle(); assertFree()
        window.setContentSize(NSSize(width: 420, height: 730))
        fullScreenPolicy(square: false, lyrics: true); settle()
        fullScreenEvent(NSWindow.willEnterFullScreenNotification)
        window.simulatedFullScreen = true
        window.setContentSize(NSSize(width: 1440, height: 900))
        fullScreenEvent(NSWindow.didEnterFullScreenNotification)
        fullScreenPolicy(square: false, lyrics: true, pinned: false); settle(); assertFree()
        precondition(window.level == .normal && contentSize() == NSSize(width: 1440, height: 900))
        fullScreenEvent(NSWindow.willExitFullScreenNotification)
        window.simulatedFullScreen = false
        window.setContentSize(NSSize(width: 420, height: 730))
        fullScreenPolicy(square: true, lyrics: true, pinned: false); settle()
        fullScreenEvent(NSWindow.didExitFullScreenNotification); settle(); assertFree()
        precondition(window.level == .normal && contentSize() == NSSize(width: 420, height: 730),
                     "Exiting full screen must retain the user's portrait lyric height and latest pin preference")
        fullScreenCoordinator.dismantle()
        window.contentView = nil; window.close()
        print("PASS: native aspect reset, coalesced geometry, square-cover mini, portrait lyrics, independent large resizing, boundary crossing, restored geometry and primary full-screen transition policies")
    }
}
