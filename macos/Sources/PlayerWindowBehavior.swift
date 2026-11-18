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
    // The old boolean remains an initializer compatibility path for isolated
    // callers. New player code always passes the explicit three-way layout.
    var pagingEnabled = false
    var layoutMode: NarrowPlayerLayout? = nil

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
        private var lastLayoutMode = NarrowPlayerLayout.original
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
            PlayerWindowDiagnostics.record("attach", window: window, force: true)
            fullScreenTransition = false; fullScreenTransitionGeneration &+= 1
            appliedSquare = nil; appliedDimButtons = nil; normalizeSquareAfterResize = false
            lastLyricsPreference = nil; expandLyricsAfterResize = false; lastLayoutMode = .original
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
            PlayerWindowDiagnostics.record(name.rawValue, window: window, force: true)
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
                    self.fullScreenTransition = false
                    PlayerWindowDiagnostics.record("fullscreen-transition-timeout", window: self.attachedWindow, force: true)
                    self.schedule()
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
            let layout = policy.layoutMode ?? (policy.pagingEnabled ? .ipadPaged : .original)
            let diagnosticPolicy = ["layout": layout.rawValue, "square": String(policy.square), "lyrics": String(policy.miniLyrics),
                                    "pinned": String(policy.pinned), "transition": String(fullScreenTransition)]
            PlayerWindowDiagnostics.record("apply.before", window: window, details: diagnosticPolicy)
            defer { PlayerWindowDiagnostics.record("apply.after", window: window, details: diagnosticPolicy) }
            let fullScreen = fullScreenTransition || window.styleMask.contains(.fullScreen)
            window.level = !fullScreen && policy.pinned ? .floating : .normal
            // Explicitly mark this viewer as a primary window even when hiding
            // the Dock changes the application to accessory activation policy.
            // All three role flags are available from macOS 13 (target: 14).
            let collection = window.collectionBehavior
                .subtracting([.auxiliary, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenNone])
                .union([.primary, .fullScreenPrimary])
            if window.collectionBehavior != collection { window.collectionBehavior = collection }
            // The idle visual-effect view samples content behind this window.
            // Keep painting transparent without changing its geometry policy.
            if window.isOpaque { window.isOpaque = false }
            if window.backgroundColor != .clear { window.backgroundColor = .clear }
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
                lastLyricsPreference = policy.miniLyrics && layout == .original
                lastLayoutMode = layout
                releaseFullScreenSizing(window)
                return
            }
            // Capture the user's lyric area before a no-lyrics transition can
            // normalize the cover to a square. Keep its height independent of
            // whether the next track sends its metadata immediately.
            if lastLyricsPreference == true { rememberLyricsPane(in: window) }
            let restoringStacked = lastLayoutMode.isPaged && layout == .original
            let wantsStackedLyrics = policy.miniLyrics && layout == .original
            let enabledLyrics = lastLyricsPreference == false && wantsStackedLyrics && !restoringStacked
            lastLyricsPreference = wantsStackedLyrics
            lastLayoutMode = layout
            if policy.miniRequest > 0 && lastMiniRequest != policy.miniRequest {
                lastMiniRequest = policy.miniRequest
                let side = min(420, max(260, window.contentLayoutRect.width))
                setSquare(layout == .squarePaged || (layout == .original && !policy.miniLyrics), window: window)
                expandLyricsAfterResize = false
                applyMinimumSize(lyrics: wantsStackedLyrics, width: side, window: window)
                let desiredHeight = layout == .ipadPaged ? max(260, window.contentLayoutRect.height)
                    : (wantsStackedLyrics ? lyricHeight(width: side, window: window) : side)
                window.setContentSize(NSSize(width: side, height: desiredHeight))
                normalizeSquareAfterResize = false
                if wantsStackedLyrics { rememberLyricsPane(in: window) }
                window.makeKeyAndOrderFront(nil)
                return
            }
            let content = window.contentRect(forFrameRect: window.frame).size
            let compact = content.width < 600
            let miniLyrics = wantsStackedLyrics && compact
            // A width-boundary crossing is a user's resize, not a request to
            // choose a new height. Preserve it, including restored cold-launch
            // geometry; expand only when lyrics are explicitly enabled here.
            if !miniLyrics { expandLyricsAfterResize = false }
            else if enabledLyrics { expandLyricsAfterResize = true }
            // Native geometry can be restored before SwiftUI publishes its
            // matching width. Use it rather than a stale full-screen policy.
            let shouldBeSquare = compact && (layout == .squarePaged || (layout == .original && !policy.miniLyrics))
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
            } else if shouldBeSquare && (normalizeSquareAfterResize || (layout == .squarePaged && abs(content.width - content.height) > 0.5)) {
                normalizeSquareAfterResize = false
                let width = max(260, content.width, window.contentMinSize.width, window.contentMinSize.height)
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
            PlayerWindowDiagnostics.record("dismantle", window: attachedWindow, force: true)
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

/// Bounded, opt-in diagnostics for the app's own native window. No media,
/// network identifiers, input text, or other applications are observed.
/// The environment path is supplied only for a dedicated diagnostic launch.
enum PlayerWindowDiagnostics {
    static func record(_ event: String, window: NSWindow?, details: [String: String] = [:], force: Bool = false) {
        guard let path = ProcessInfo.processInfo.environment["FUSIONPLAY_WINDOW_DIAGNOSTICS_PATH"],
              path.hasPrefix("/"), Thread.isMainThread else { return }
        MainActor.assumeIsolated { Storage.record(event, window: window, details: details, force: force, path: path) }
    }

    @MainActor private enum Storage {
        private static var signatures: [String: Data] = [:]
        private static let limit = 1_048_576

        static func record(_ event: String, window: NSWindow?, details: [String: String], force: Bool, path: String) {
            var value: [String: Any] = [
                "event": event, "policy": details,
                "activationPolicy": NSApp.activationPolicy().rawValue,
                "presentationOptions": NSApp.presentationOptions.rawValue,
                "appActive": NSApp.isActive,
                "keyWindow": NSApp.keyWindow?.windowNumber as Any? ?? NSNull(),
                "mainWindow": NSApp.mainWindow?.windowNumber as Any? ?? NSNull(),
                "eventType": NSApp.currentEvent?.type.rawValue as Any? ?? NSNull(),
                "eventModifiers": NSApp.currentEvent?.modifierFlags.rawValue as Any? ?? NSNull()
            ]
            if let window {
                let button = window.standardWindowButton(.zoomButton)
                value["window"] = [
                    "number": window.windowNumber, "class": String(describing: type(of: window)),
                    "delegate": window.delegate.map { String(describing: type(of: $0)) } ?? "nil",
                    "frame": NSStringFromRect(window.frame), "contentLayout": NSStringFromRect(window.contentLayoutRect),
                    "styleMask": window.styleMask.rawValue, "collectionBehavior": window.collectionBehavior.rawValue,
                    "fullScreen": window.styleMask.contains(.fullScreen), "zoomed": window.isZoomed,
                    "level": window.level.rawValue, "visible": window.isVisible,
                    "key": window.isKeyWindow, "main": window.isMainWindow,
                    "canBecomeKey": window.canBecomeKey, "canBecomeMain": window.canBecomeMain,
                    "inLiveResize": window.inLiveResize, "opaque": window.isOpaque,
                    "minSize": NSStringFromSize(window.minSize), "maxSize": NSStringFromSize(window.maxSize),
                    "contentMinSize": NSStringFromSize(window.contentMinSize), "contentMaxSize": NSStringFromSize(window.contentMaxSize),
                    "aspectRatio": NSStringFromSize(window.aspectRatio), "contentAspectRatio": NSStringFromSize(window.contentAspectRatio),
                    "resizeIncrements": NSStringFromSize(window.resizeIncrements), "contentResizeIncrements": NSStringFromSize(window.contentResizeIncrements),
                    "screenFrame": window.screen.map { NSStringFromRect($0.frame) } ?? "nil",
                    "screenVisibleFrame": window.screen.map { NSStringFromRect($0.visibleFrame) } ?? "nil",
                    "zoomButtonEnabled": button?.isEnabled as Any? ?? NSNull(),
                    "zoomButtonAction": button?.action.map(NSStringFromSelector) ?? "nil",
                    "zoomButtonTarget": button?.target.map { String(describing: type(of: $0)) } ?? "nil",
                    "accessibilityFullScreenButton": window.accessibilityFullScreenButton() != nil
                ]
            } else { value["window"] = NSNull() }
            let key = event + ":" + String(window?.windowNumber ?? -1)
            guard let signature = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  force || signatures[key] != signature else { return }
            signatures[key] = signature
            if signatures.count > 32 { signatures = [key: signature] }
            value["uptime"] = ProcessInfo.processInfo.systemUptime
            guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count < limit else { return }
            data.append(0x0a)
            let url = URL(fileURLWithPath: path)
            do {
                let manager = FileManager.default
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !manager.fileExists(atPath: path) {
                    guard manager.createFile(atPath: path, contents: nil,
                                             attributes: [.posixPermissions: NSNumber(value: 0o600)]) else { return }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size + UInt64(data.count) > UInt64(limit) {
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                }
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostics must never change window behavior on a write failure.
            }
        }
    }
}

/// Keep SwiftUI's eligibility consistent with the native window policy. Its
/// automatic content-size inference can otherwise restore fullScreenNone.
struct PlayerFullScreenEligibility: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
#if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            content.windowFullScreenBehavior(.enabled)
        } else { content }
#else
        content
#endif
    }
}
