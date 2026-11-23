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
        precondition(contentSize().height > contentSize().width && window.contentMinSize.height == 260)
        // Subsequent updates must retain a manually chosen portrait size.
        window.setContentSize(NSSize(width: 360, height: 620))
        apply(square: false, request: 1, lyrics: true, pinned: true); settle(); assertFree()
        precondition(window.level == .floating && abs(contentSize().height - 620) < 1)
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(contentSize().height > contentSize().width)
        // An actual no-lyrics interval must not erase the manually expanded
        // lyric pane when a later track starts supplying lyrics again.
        window.setContentSize(NSSize(width: 360, height: 800))
        apply(square: false, request: 2, lyrics: true); settle()
        apply(square: true, request: 2, lyrics: false); settle()
        precondition(contentSize() == NSSize(width: 360, height: 360))
        apply(square: false, request: 2, lyrics: true); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 360, height: 800),
                     "A no-lyrics gap replaced the user's lyric pane height with the default ratio")

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
        precondition(window.contentMinSize.height == 260, "Native minimum must stay independent of measured cover width")
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
        precondition(window.contentMinSize.height == 260)
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
        let pagingCoordinator = PlayerWindowBehavior.Coordinator()
        view.coordinator = pagingCoordinator
        func pagingPolicy(lyrics: Bool, enabled: Bool = true, request: Int = 0) {
            pagingCoordinator.update(view, policy: PlayerWindowBehavior(square: !lyrics, miniRequest: request,
                miniLyrics: lyrics, dimButtons: false, pinned: false, duration: 0, pagingEnabled: enabled))
        }
        window.setContentSize(NSSize(width: 420, height: 300))
        pagingPolicy(lyrics: false); settle(); assertFree()
        for lyrics in [true, false, true] {
            pagingPolicy(lyrics: lyrics); settle(); assertFree()
            precondition(contentSize() == NSSize(width: 420, height: 300),
                         "Paged metadata/lyric changes resized the user's window")
            precondition(window.contentMinSize == NSSize(width: 260, height: 260))
        }
        pagingPolicy(lyrics: true, enabled: false); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 420, height: 556),
                     "Restoring the stacked layout must only add its necessary lyric space")
        pagingPolicy(lyrics: true); settle(); assertFree()
        window.setContentSize(NSSize(width: 260, height: 260))
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        pagingPolicy(lyrics: true); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 260, height: 260),
                     "Paged resize inherited the square-cover lyric minimum")
        for lyrics in [false, true, false] {
            pagingPolicy(lyrics: lyrics); settle(); assertFree()
            precondition(contentSize() == NSSize(width: 260, height: 260),
                         "Minimum-size paged stop/metadata updates changed the window size")
        }
        pagingCoordinator.dismantle()
        let modesCoordinator = PlayerWindowBehavior.Coordinator()
        view.coordinator = modesCoordinator
        func modePolicy(_ mode: NarrowPlayerLayout, lyrics: Bool) {
            modesCoordinator.update(view, policy: PlayerWindowBehavior(square: false, miniRequest: 0,
                miniLyrics: lyrics, dimButtons: false, pinned: false, duration: 0, layoutMode: mode))
        }
        window.setContentSize(NSSize(width: 420, height: 700))
        modePolicy(.squarePaged, lyrics: true); settle()
        precondition(contentSize() == NSSize(width: 420, height: 420)
                     && window.contentAspectRatio == NSSize(width: 1, height: 1))
        for lyrics in [false, true, false] {
            modePolicy(.squarePaged, lyrics: lyrics); settle()
            precondition(contentSize() == NSSize(width: 420, height: 420),
                         "Square paging media/page policy changed the window size")
        }
        window.setContentSize(NSSize(width: 840, height: 600))
        modePolicy(.squarePaged, lyrics: true); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 840, height: 600))
        window.setContentSize(NSSize(width: 420, height: 420))
        modePolicy(.squarePaged, lyrics: true); settle()
        precondition(window.contentAspectRatio == NSSize(width: 1, height: 1))
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.simulatedFullScreen = true; window.setContentSize(NSSize(width: 1440, height: 900))
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        modePolicy(.squarePaged, lyrics: true); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 1440, height: 900))
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        window.simulatedFullScreen = false; window.setContentSize(NSSize(width: 420, height: 420))
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        settle()
        precondition(contentSize() == NSSize(width: 420, height: 420)
                     && window.contentAspectRatio == NSSize(width: 1, height: 1))
        modePolicy(.ipadPaged, lyrics: true); settle(); assertFree()
        window.setContentSize(NSSize(width: 420, height: 300))
        modePolicy(.ipadPaged, lyrics: false); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 420, height: 300))
        modePolicy(.original, lyrics: true); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 420, height: 556))
        modesCoordinator.dismantle()
        // Settled cover windows scale their complete presentation on native
        // top/side edges; only the lower lyric-edge interaction owns pane height.
        let coverScaleCoordinator = PlayerWindowBehavior.Coordinator()
        view.coordinator = coverScaleCoordinator
        func coverScalePolicy(resizing: Bool = false, hasTrack: Bool = true, pinned: Bool = false) {
            coverScaleCoordinator.update(view, policy: PlayerWindowBehavior(square: false, miniRequest: 0,
                miniLyrics: true, dimButtons: false, pinned: pinned, duration: 0, layoutMode: .original,
                coverLyricsResizing: resizing, hasTrack: hasTrack, scalesCoverProportionally: true))
        }
        func assertCoverAspect(_ expected: NSSize) {
            let ratio = window.contentAspectRatio
            precondition(window.aspectRatio == .zero && ratio.width > 0 && ratio.height > 0,
                         "The settled cover lost its native proportional resizing constraint")
            precondition(abs(ratio.width / ratio.height - expected.width / expected.height) < 0.00001,
                         "Native scaling used a square or stale pane-height aspect")
            precondition(window.contentMinSize == NSSize(width: 260, height: 260),
                         "Proportional cover scaling published a second pane-dependent minimum")
        }
        window.setContentSize(NSSize(width: 420, height: 640))
        coverScalePolicy(); settle()
        let settledCover = contentSize()
        precondition(settledCover == NSSize(width: 420, height: 640))
        assertCoverAspect(settledCover)
        for pinned in [true, false, true] {
            coverScalePolicy(pinned: pinned); settle()
            precondition(contentSize() == settledCover, "A media/pin refresh changed the settled cover size")
            assertCoverAspect(settledCover)
        }
        coverScalePolicy(resizing: true); settle(); assertFree()
        window.setContentSize(NSSize(width: 420, height: 455))
        coverScalePolicy(resizing: true); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 420, height: 455),
                     "Live lyric-edge shrinking was clamped before it could reach the collapse threshold")
        window.setContentSize(NSSize(width: 420, height: 600))
        coverScalePolicy(resizing: true); settle(); assertFree()
        coverScalePolicy(); settle()
        let newlySettledCover = contentSize()
        precondition(newlySettledCover == NSSize(width: 420, height: 600),
                     "Finishing a lyric-edge resize reapplied the previous pane height")
        assertCoverAspect(newlySettledCover)
        // A side/top resize reduces the entire 420:600 presentation. The lyric
        // pane is then naturally less than 136pt and must not jump back open.
        window.setContentSize(NSSize(width: 260, height: 260 * 600 / 420))
        let proportionallySmall = contentSize()
        precondition(proportionallySmall.height - proportionallySmall.width > 1
                     && proportionallySmall.height - proportionallySmall.width < 136)
        for _ in 0..<3 {
            coverScalePolicy(); settle()
            precondition(contentSize() == proportionallySmall,
                         "A proportionally scaled lyric pane was forced back to 136pt")
            assertCoverAspect(proportionallySmall)
        }
        fullScreenEvent(NSWindow.willEnterFullScreenNotification); assertFree()
        window.simulatedFullScreen = true
        window.setContentSize(NSSize(width: 1440, height: 900))
        fullScreenEvent(NSWindow.didEnterFullScreenNotification)
        coverScalePolicy(resizing: true); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 1440, height: 900),
                     "The proportional-cover policy resized a native full-screen window")
        fullScreenEvent(NSWindow.willExitFullScreenNotification)
        window.simulatedFullScreen = false
        window.setContentSize(NSSize(width: 420, height: 600))
        fullScreenEvent(NSWindow.didExitFullScreenNotification)
        coverScalePolicy(); settle()
        precondition(contentSize() == NSSize(width: 420, height: 600))
        assertCoverAspect(contentSize())
        coverScalePolicy(hasTrack: false); settle(); assertFree()
        window.setContentSize(NSSize(width: 310, height: 280))
        coverScalePolicy(resizing: true, hasTrack: false); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 310, height: 280),
                     "Idle cover state still enforced a stored expanded lyric height")
        window.setContentSize(NSSize(width: 840, height: 430))
        coverScalePolicy(); settle(); assertFree()
        precondition(contentSize() == NSSize(width: 840, height: 430),
                     "Crossing to the wide player retained the compact proportional constraint")
        coverScaleCoordinator.dismantle()
        window.contentView = nil; window.close()
        print("PASS: native aspect reset, coalesced geometry, square-cover mini, portrait lyrics, independent large resizing, boundary crossing, restored geometry, proportional cover scaling and primary full-screen/idle transition policies")
    }
}
