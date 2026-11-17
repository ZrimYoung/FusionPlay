import AppKit
import SwiftUI

/// Owns native player-window policy without replacing SwiftUI's window delegate.
/// Only the cover-only mini player has a fixed aspect ratio; lyrics and expanded
/// players resize independently in both dimensions.
struct PlayerWindowBehavior: NSViewRepresentable {
    let square: Bool
    let miniRequest: Int
    let miniLyrics: Bool
    let dimButtons: Bool
    let pinned: Bool
    let duration: Double

    final class WindowAttachmentView: NSView {
        weak var coordinator: Coordinator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            coordinator?.windowChanged(for: self)
        }
    }
    final class Coordinator {
        private weak var view: WindowAttachmentView?
        private weak var attachedWindow: NSWindow?
        private var windowObservers: [NSObjectProtocol] = []
        private var fullScreenTransition = false
        private var fullScreenTransitionGeneration: UInt64 = 0
        private var latest: PlayerWindowBehavior?
        private var generation: UInt64 = 0
        private var appliedSquare: Bool?
        private var appliedDimButtons: Bool?
        private var normalizeSquareAfterResize = false
        private var lastLyricsPreference: Bool?
        private var expandLyricsAfterResize = false
        private var lastMiniRequest = 0
        private var preferredLyricsPaneHeight: CGFloat?

        func update(_ view: WindowAttachmentView, policy: PlayerWindowBehavior) {
            self.view = view
            latest = policy
            schedule()
        }
        func windowChanged(for view: WindowAttachmentView) {
            self.view = view
            attach(to: view.window)
            schedule()
        }
        private func attach(to window: NSWindow?) {
            guard window !== attachedWindow else { return }
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers = []; attachedWindow = window
            fullScreenTransition = false; fullScreenTransitionGeneration &+= 1
            appliedSquare = nil; appliedDimButtons = nil; normalizeSquareAfterResize = false
            lastLyricsPreference = nil; expandLyricsAfterResize = false
            preferredLyricsPaneHeight = nil
            if let window {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
                ) { [weak self] _ in self?.schedule() })
                for name in [NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                             NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                    windowObservers.append(NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self, weak window] note in
                        guard let self, let window else { return }
                        self.fullScreenChanged(note.name, window: window)
                    })
                }
            }
        }
        private func fullScreenChanged(_ name: Notification.Name, window: NSWindow) {
            fullScreenTransitionGeneration &+= 1
            fullScreenTransition = name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification
            if fullScreenTransition {
                // AppKit must be able to animate from either mini layout into
                // a screen-shaped window and restore its original frame itself.
                releaseFullScreenSizing(window)
                window.level = .normal
                let token = fullScreenTransitionGeneration
                // AppKit reports a failed transition through its window delegate,
                // which belongs to SwiftUI. Release our temporary guard if that
                // delegate receives failure instead of a did-enter/exit event.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.fullScreenTransitionGeneration == token else { return }
                    self.fullScreenTransition = false; self.schedule()
                }
            }
            schedule()
        }
        private func releaseFullScreenSizing(_ window: NSWindow) {
            expandLyricsAfterResize = false
            normalizeSquareAfterResize = false
            let unit = NSSize(width: 1, height: 1)
            if appliedSquare != false || window.aspectRatio != .zero || window.contentAspectRatio != .zero ||
                window.resizeIncrements != unit || window.contentResizeIncrements != unit {
                setSquare(false, window: window)
            }
            let minimum = NSSize(width: 260, height: 260)
            if window.contentMinSize != minimum { window.contentMinSize = minimum }
        }
        private func schedule() {
            generation &+= 1
            let token = generation
            // SwiftUI can issue several geometry/state updates in one turn.
            // Read the newest policy at execution time; an old square update
            // must never re-lock a window after the user enlarged it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, let view = self.view,
                      let window = view.window, let policy = self.latest else { return }
                self.attach(to: window)
                self.apply(policy, to: window)
            }
        }
        private func rememberLyricsPane(in window: NSWindow) {
            guard !window.inLiveResize else { return }
            let content = window.contentRect(forFrameRect: window.frame).size
            guard content.width < 600, content.height >= content.width + 136 else { return }
            preferredLyricsPaneHeight = content.height - content.width
        }
        private func apply(_ policy: PlayerWindowBehavior, to window: NSWindow) {
            let fullScreen = fullScreenTransition || window.styleMask.contains(.fullScreen)
            window.level = !fullScreen && policy.pinned ? .floating : .normal
            // Explicitly mark this viewer as a primary window even when hiding
            // the Dock changes the application to accessory activation policy.
            // All three role flags are available from macOS 13 (target: 14).
            let collection = window.collectionBehavior
                .subtracting([.auxiliary, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenNone])
                .union([.primary, .fullScreenPrimary])
            if window.collectionBehavior != collection { window.collectionBehavior = collection }
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            let style = window.styleMask.union([.fullSizeContentView, .resizable])
            if window.styleMask != style { window.styleMask = style }
            if appliedDimButtons != policy.dimButtons {
                appliedDimButtons = policy.dimButtons
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = max(0, policy.duration)
                    for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                        window.standardWindowButton(kind)?.animator().alphaValue = policy.dimButtons ? 0.22 : 1
                    }
                }
            }
            if fullScreen {
                // Consume changing media/appearance state without changing the
                // native full-screen frame or the frame AppKit is restoring.
                lastLyricsPreference = policy.miniLyrics
                releaseFullScreenSizing(window)
                return
            }
            // Capture the user's lyric area before a no-lyrics transition can
            // normalize the cover to a square. Keep its height independent of
            // whether the next track sends its metadata immediately.
            if lastLyricsPreference == true { rememberLyricsPane(in: window) }
            let enabledLyrics = lastLyricsPreference == false && policy.miniLyrics
            lastLyricsPreference = policy.miniLyrics
            if policy.miniRequest > 0 && lastMiniRequest != policy.miniRequest {
                lastMiniRequest = policy.miniRequest
                let side = min(420, max(260, window.contentLayoutRect.width))
                setSquare(!policy.miniLyrics, window: window)
                expandLyricsAfterResize = false
                applyMinimumSize(lyrics: policy.miniLyrics, width: side, window: window)
                let desiredHeight = policy.miniLyrics ? lyricHeight(width: side, window: window) : side
                window.setContentSize(NSSize(width: side, height: desiredHeight))
                normalizeSquareAfterResize = false
                if policy.miniLyrics { rememberLyricsPane(in: window) }
                window.makeKeyAndOrderFront(nil)
                return
            }
            let content = window.contentRect(forFrameRect: window.frame).size
            let compact = content.width < 600
            let miniLyrics = policy.miniLyrics && compact
            // A width-boundary crossing is a user's resize, not a request to
            // choose a new height. Preserve it, including restored cold-launch
            // geometry; expand only when lyrics are explicitly enabled here.
            if !miniLyrics { expandLyricsAfterResize = false }
            else if enabledLyrics { expandLyricsAfterResize = true }
            // Native geometry can be restored before SwiftUI publishes its
            // matching width. Use it rather than a stale full-screen policy.
            let shouldBeSquare = compact && !policy.miniLyrics
            let squareRatio = NSSize(width: 1, height: 1)
            let nativeConstraintChanged = shouldBeSquare
                ? window.contentAspectRatio != squareRatio
                : window.aspectRatio != .zero || window.contentAspectRatio != .zero ||
                  window.resizeIncrements != squareRatio || window.contentResizeIncrements != squareRatio
            if appliedSquare != shouldBeSquare || nativeConstraintChanged {
                setSquare(shouldBeSquare, window: window)
            }
            guard !window.inLiveResize else { return }
            let minimumHeight = applyMinimumSize(lyrics: miniLyrics, width: content.width, window: window)
            if miniLyrics && content.height < minimumHeight {
                // Cover and its controls occupy a square; only grow enough to
                // leave a real lyric pane underneath, not to a preferred ratio.
                window.setContentSize(NSSize(width: content.width, height: minimumHeight))
            }
            if miniLyrics && expandLyricsAfterResize {
                expandLyricsAfterResize = false
                let height = lyricHeight(width: content.width, window: window)
                if content.height < height {
                    window.setContentSize(NSSize(width: content.width, height: height))
                }
            } else if shouldBeSquare && normalizeSquareAfterResize {
                normalizeSquareAfterResize = false
                let width = max(260, content.width)
                window.setContentSize(NSSize(width: width, height: width))
            }
            if miniLyrics { rememberLyricsPane(in: window) }
        }
        @discardableResult private func applyMinimumSize(lyrics: Bool, width: CGFloat, window: NSWindow) -> CGFloat {
            let height = lyrics ? width + 136 : 260
            // The Window scene owns the fixed 260-point native minimum.
            // Do not publish a second width-dependent contentMinSize here:
            // SwiftUI restores its own minimum on subsequent media updates.
            // Enforce the square-cover lyric area by clamping actual geometry
            // after a resize instead, outside AppKit's measurement pass.
            let minimum = NSSize(width: 260, height: 260)
            let chrome = max(0, window.frame.height - window.contentLayoutRect.height)
            if window.contentMinSize.width != minimum.width || window.contentMinSize.height < minimum.height
                || window.contentMinSize.height > minimum.height + chrome {
                window.contentMinSize = minimum
            }
            return height
        }
        private func lyricHeight(width: CGFloat, window: NSWindow) -> CGFloat {
            let minimum = width + 136
            let preferred = max(minimum, preferredLyricsPaneHeight.map { width + $0 } ?? width * 1.65)
            let available = window.screen.map { max(minimum, $0.visibleFrame.height - 48) } ?? preferred
            return min(preferred, available)
        }
        private func setSquare(_ square: Bool, window: NSWindow) {
            // AppKit's frame/content aspect constraints and resize increments
            // are distinct, mutually exclusive settings. Clear both families,
            // including constraints retained from previous app versions.
            window.aspectRatio = .zero
            window.contentAspectRatio = .zero
            window.resizeIncrements = NSSize(width: 1, height: 1)
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            appliedSquare = square
            normalizeSquareAfterResize = square
            if square { window.contentAspectRatio = NSSize(width: 1, height: 1) }
        }
        func dismantle() {
            generation &+= 1
            fullScreenTransitionGeneration &+= 1; fullScreenTransition = false
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers = []; attachedWindow = nil; view = nil; latest = nil
        }
        deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.coordinator = context.coordinator
        return view
    }
    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        context.coordinator.update(view, policy: self)
    }
    static func dismantleNSView(_ view: WindowAttachmentView, coordinator: Coordinator) {
        view.coordinator = nil
        coordinator.dismantle()
    }
}
