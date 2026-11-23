import AppKit
import SwiftUI

private final class ConstraintWindow: NSWindow {
    var simulatedLiveResize = false
    var simulatedFullScreen = false
    var contentWrites = 0
    var frameWrites = 0
    override var inLiveResize: Bool { simulatedLiveResize || super.inLiveResize }
    override var styleMask: NSWindow.StyleMask {
        get { simulatedFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue.subtracting(.fullScreen) }
    }
    override func setContentSize(_ size: NSSize) { contentWrites += 1; super.setContentSize(size) }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) { frameWrites += 1; super.setFrame(frameRect, display: flag) }
}
private final class DelegateWitness: NSObject, NSWindowDelegate {}

@MainActor private final class HostedMedia: ObservableObject {
    @Published var revision = 0
}
private final class HostedConstraintPanel: NSPanel {
    var frameWrites = 0
    var contentWrites = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) { frameWrites += 1; super.setFrame(frameRect, display: flag) }
    override func setContentSize(_ size: NSSize) { contentWrites += 1; super.setContentSize(size) }
}
private struct HostedMinimumRoot: View {
    @ObservedObject var media: HostedMedia
    var body: some View {
        GeometryReader { _ in
            ZStack {
                Text("Media revision \(media.revision)")
                PlayerWindowBehavior(square: false, miniRequest: 0, miniLyrics: true,
                    dimButtons: false, pinned: false, duration: 0, layoutMode: .original,
                    hasTrack: true, scalesCoverProportionally: true)
                    .frame(width: 0, height: 0)
            }
        }.frame(minWidth: 260, minHeight: 260)
    }
}

@main struct WindowAspectMinimumSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        do { try check(); exit(0) }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func check() throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "WindowAspectMinimum", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func pump(_ duration: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        func make(_ size: NSSize) -> (ConstraintWindow, PlayerWindowBehavior.Coordinator, PlayerWindowBehavior.WindowAttachmentView, DelegateWitness) {
            let window = ConstraintWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.alphaValue = 0; window.isReleasedWhenClosed = false
            let delegate = DelegateWitness(); window.delegate = delegate
            let coordinator = PlayerWindowBehavior.Coordinator()
            let view = PlayerWindowBehavior.WindowAttachmentView(); view.coordinator = coordinator
            window.contentView = view
            return (window, coordinator, view, delegate)
        }
        func policy(_ mode: NarrowPlayerLayout = .original, lyrics: Bool = true, dragging: Bool = false,
                    hasTrack: Bool = true) -> PlayerWindowBehavior {
            PlayerWindowBehavior(square: mode == .squarePaged, miniRequest: 0, miniLyrics: lyrics,
                dimButtons: false, pinned: true, duration: 0, layoutMode: mode,
                coverLyricsResizing: dragging, hasTrack: hasTrack, scalesCoverProportionally: true)
        }
        func content(_ window: NSWindow) -> NSSize { window.contentRect(forFrameRect: window.frame).size }
        func assertOrdinary(_ window: NSWindow) throws {
            try require(window.contentAspectRatio == .zero && window.aspectRatio == .zero,
                        "Released state retained a native aspect lock")
            try require(window.contentMinSize == NSSize(width: 260, height: 260),
                        "Released state retained proportional minimum \(window.contentMinSize)")
        }
        func assertMinimum(_ window: NSWindow, _ expected: NSSize) throws {
            try require(abs(window.contentMinSize.width - expected.width) < 0.01
                        && abs(window.contentMinSize.height - expected.height) < 0.01,
                        "Wrong actual native minimum \(window.contentMinSize), expected \(expected)")
            try require(window.minSize.width >= 260 && window.minSize.height >= 260,
                        "Frame minimum failed to protect both 260-point dimensions")
        }
        let ratios: [(Double, NSSize, NSSize)] = [
            (0.2, NSSize(width: 400, height: 2000), NSSize(width: 260, height: 1300)),
            (0.344, NSSize(width: 344, height: 1000), NSSize(width: 260, height: 756)),
            (0.6, NSSize(width: 360, height: 600), NSSize(width: 260, height: 434)),
            (1, NSSize(width: 400, height: 400), NSSize(width: 260, height: 260))
        ]
        for (ratio, size, minimum) in ratios {
            let (window, coordinator, view, delegate) = make(size)
            defer { coordinator.dismantle(); window.contentView = nil; window.close() }
            let mode: NarrowPlayerLayout = ratio == 1 ? .squarePaged : .original
            let state = policy(mode, lyrics: ratio != 1)
            window.simulatedLiveResize = true
            coordinator.update(view, policy: state); pump()
            try assertMinimum(window, minimum)
            // A scene can clear the ratio as well as the minimum while the
            // representable policy remains unchanged. Native start restores it.
            if ratio != 1 {
                window.contentAspectRatio = .zero
                window.contentMinSize = NSSize(width: 260, height: 260)
                NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
                try assertMinimum(window, minimum)
            }
            let nativeAspect = window.contentAspectRatio
            try require(abs(nativeAspect.width / nativeAspect.height - ratio) < 0.00001,
                        "Wrong active ratio \(nativeAspect)")
            var rounded = window.frame; rounded.size.width += 0.5
            window.setFrame(rounded, display: false)
            let afterRounding = window.contentAspectRatio
            window.frameWrites = 0; window.contentWrites = 0
            for _ in 0..<3 { coordinator.update(view, policy: state); pump() }
            try require(window.contentAspectRatio == nativeAspect, "ratio=\(ratio), settled=\(nativeAspect), rounded=\(afterRounding), applied=\(window.contentAspectRatio), frameAspect=\(window.aspectRatio), increments=\(window.resizeIncrements)/\(window.contentResizeIncrements), live=\(window.inLiveResize)")
            try require(window.frameWrites == 0 && window.contentWrites == 0,
                        "Policy competed with AppKit by writing geometry during live resize")
            // Model the plain minimum that SwiftUI may restore while the policy
            // value is unchanged. Only real native notifications repair it.
            window.contentMinSize = NSSize(width: 260, height: 260)
            NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            try assertMinimum(window, minimum)
            window.contentMinSize = NSSize(width: 260, height: 260)
            if ratio != 1 { window.contentAspectRatio = .zero }
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
            try assertMinimum(window, minimum)
            try require(window.contentAspectRatio == nativeAspect && window.contentWrites == 0,
                        "Native revalidation changed ratio/frame instead of constraints")
            window.simulatedLiveResize = false
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window); pump()
            let writes = window.contentWrites
            coordinator.update(view, policy: state); pump()
            try require(window.contentWrites == writes, "Settled updates repeatedly rewrote native geometry")
            try require(window.delegate === delegate, "Sizing policy replaced the existing window delegate")
            try require(!window.isVisible && window.alphaValue == 0, "Ratio check showed a window")
            print("PASS: actual ratio \(ratio), minimum \(minimum), live rounding, native notification repair and delegate")
        }
        do {
            let (window, coordinator, view, delegate) = make(NSSize(width: 211, height: 613))
            defer { coordinator.dismantle(); window.contentView = nil; window.close() }
            window.simulatedLiveResize = true
            coordinator.update(view, policy: policy()); pump()
            try require(window.contentWrites == 0, "An illegal frame was explicitly repaired mid-drag")
            window.simulatedLiveResize = false
            NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window); pump()
            let fixed = content(window), writes = window.contentWrites
            try require(fixed.width >= 260 && fixed.height >= 260 && writes <= 1,
                        "Undersized 211-point frame failed one-time end repair: \(fixed), writes=\(writes)")
            for _ in 0..<3 { coordinator.update(view, policy: policy()); pump() }
            try require(window.contentWrites == writes && window.delegate === delegate,
                        "End repair oscillated or replaced the delegate")
            print("PASS: illegal 211-point width repaired once after live resize")
        }
        do {
            let (window, coordinator, view, delegate) = make(NSSize(width: 344, height: 1000))
            defer { coordinator.dismantle(); window.contentView = nil; window.close() }
            coordinator.update(view, policy: policy()); pump()
            try assertMinimum(window, NSSize(width: 260, height: 756))
            // An owned bottom release happens before SwiftUI publishes its
            // dragging state. A normal didResize with zero ratio must pass.
            window.contentAspectRatio = .zero
            window.contentMinSize = NSSize(width: 260, height: 260)
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
            try assertOrdinary(window)
            coordinator.update(view, policy: policy()); pump()
            try assertMinimum(window, NSSize(width: 260, height: 756))
            let grip = CoverLyricsResizeGrip(frame: NSRect(x: 0, y: 0, width: 344, height: 14))
            view.addSubview(grip); grip.expanded = true
            var dragging = false, expanded = true
            func update() { coordinator.update(view, policy: policy(expanded ? .original : .squarePaged,
                lyrics: expanded, dragging: dragging)) }
            grip.onDraggingChanged = { dragging = $0; update() }
            grip.onExpansionChanged = { expanded = $0; update() }
            defer { grip.invalidate(); grip.removeFromSuperview() }
            try require(grip.accessibilityPerformDecrement(), "Actual bottom grip rejected owned collapse action")
            // This assertion is synchronous: no SwiftUI/Coordinator turn has run.
            try assertOrdinary(window)
            NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
            try assertOrdinary(window)
            pump(0.30)
            try require(!expanded && window.contentAspectRatio == NSSize(width: 1, height: 1), "Collapsed cover did not restore square policy")
            try require(grip.accessibilityPerformIncrement(), "Actual bottom grip rejected owned expansion action")
            try assertOrdinary(window)
            pump(0.30)
            try require(expanded && !dragging && window.contentMinSize.height > 260,
                        "Expanded bottom grip did not restore compatible portrait minimum")
            let beforeIdle = window.frame
            coordinator.update(view, policy: policy(hasTrack: false)); pump(); try assertOrdinary(window)
            try require(window.frame == beforeIdle, "Idle minimum release changed current geometry")
            coordinator.update(view, policy: policy()); pump()
            let beforeFullScreen = window.frame
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
            try assertOrdinary(window)
            window.simulatedFullScreen = true
            NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
            coordinator.update(view, policy: policy()); pump(); try assertOrdinary(window)
            try require(window.frame == beforeFullScreen && window.level == .normal, "Full-screen guard changed frame or pinning")
            NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
            window.simulatedFullScreen = false
            NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window); pump()
            try require(window.contentMinSize.height > 260 && window.level == .floating && window.delegate === delegate,
                        "Full-screen return failed to restore ratio minimum/pinning/delegate")
            try require(!window.isVisible && window.alphaValue == 0, "Lifecycle check showed a window")
            print("PASS: synchronous actual bottom-grip release/reopen, idle and full-screen minimum lifecycle")
        }
        do {
            // Reproduce NSHostingView's real contentMinSize updates, rather than
            // only assigning a simulated minimum from the native fixture.
            let media = HostedMedia()
            let host = NSHostingView(rootView: HostedMinimumRoot(media: media))
            let window = HostedConstraintPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 900),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.alphaValue = 0; window.isReleasedWhenClosed = false
            host.frame = NSRect(x: 0, y: 0, width: 260, height: 900); window.contentView = host
            defer { window.contentView = nil; window.close() }
            func hostedPump(_ duration: Double = 0.10) {
                let end = Date().addingTimeInterval(duration)
                repeat { host.layoutSubtreeIfNeeded(); pump(0.005) } while Date() < end
            }
            func attachment(in view: NSView) -> PlayerWindowBehavior.WindowAttachmentView? {
                if let view = view as? PlayerWindowBehavior.WindowAttachmentView { return view }
                for child in view.subviews { if let result = attachment(in: child) { return result } }
                return nil
            }
            let originalSizing = host.sizingOptions
            window.frameWrites = 0; window.contentWrites = 0
            hostedPump()
            guard let view = attachment(in: host), let coordinator = view.coordinator else {
                throw NSError(domain: "WindowAspectMinimum", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Actual hosted sizing attachment was not created"])
            }
            try assertMinimum(window, NSSize(width: 260, height: 900))
            for revision in 1...3 {
                media.revision = revision; hostedPump()
                try assertMinimum(window, NSSize(width: 260, height: 900))
                try require(window.contentAspectRatio == NSSize(width: 260, height: 900),
                            "Actual host media update reset proportional aspect")
            }
            try require(coordinator.minimumCorrectionWritesForCheck > 0,
                        "Actual host did not exercise the deferred minimum-repair path")
            window.contentMinSize = NSSize(width: 260, height: 1400)
            coordinator.update(view, policy: policy()); hostedPump()
            try assertMinimum(window, NSSize(width: 260, height: 1400))
            let idleWrites = coordinator.minimumCorrectionWritesForCheck
            hostedPump(0.50)
            try require(coordinator.minimumCorrectionWritesForCheck == idleWrites,
                        "Minimum observer entered an idle repair loop")
            try require(window.frameWrites == 0 && window.contentWrites == 0,
                        "Hosted minimum repair wrote native geometry")
            try require(host.sizingOptions == originalSizing && !window.isVisible && window.alphaValue == 0,
                        "Hosted repair changed default host sizing options or showed a window")
            print("PASS: same actual NSHostingView survives three media updates, preserves larger minimum, 500ms idle has no writes, frame/content writes remain zero")
        }
        do {
            let (oldWindow, coordinator, view, delegate) = make(NSSize(width: 260, height: 900))
            let newWindow = ConstraintWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 800),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            newWindow.alphaValue = 0; newWindow.isReleasedWhenClosed = false
            defer { coordinator.dismantle(); oldWindow.contentView = nil; newWindow.contentView = nil; oldWindow.close(); newWindow.close() }
            coordinator.update(view, policy: policy()); pump()
            let beforeStale = coordinator.minimumCorrectionWritesForCheck
            oldWindow.contentMinSize = NSSize(width: 260, height: 260)
            coordinator.update(view, policy: policy(hasTrack: false))
            pump()
            try assertOrdinary(oldWindow)
            try require(coordinator.minimumCorrectionWritesForCheck == beforeStale,
                        "Queued repair ignored the latest idle policy")
            coordinator.update(view, policy: policy()); pump()
            oldWindow.contentMinSize = NSSize(width: 260, height: 260)
            oldWindow.contentView = nil; newWindow.contentView = view
            coordinator.update(view, policy: policy()); pump()
            try require(oldWindow.contentMinSize == NSSize(width: 260, height: 260),
                        "Old queued observation changed a detached window")
            try require(newWindow.contentMinSize.height >= ceil(260 * 800 / 300),
                        "Reattached observer failed to protect the new window")
            let beforeDismantle = coordinator.minimumCorrectionWritesForCheck
            newWindow.contentMinSize = NSSize(width: 260, height: 260)
            coordinator.dismantle(); pump()
            try require(newWindow.contentMinSize == NSSize(width: 260, height: 260)
                        && coordinator.minimumCorrectionWritesForCheck == beforeDismantle,
                        "Dismantled observer ran queued correction")
            newWindow.contentMinSize = NSSize(width: 270, height: 270); pump()
            try require(coordinator.minimumCorrectionWritesForCheck == beforeDismantle && oldWindow.delegate === delegate,
                        "Teardown left an active observer or changed the native delegate")
            print("PASS: queued repair uses latest policy and invalidates old-window/teardown generations")
        }
        try require(NSApp.activationPolicy() == .prohibited && !NSRunningApplication.current.isActive,
                    "Constraint check activated the application")
        print("PASS: silent native aspect/minimum regression; no ordering, activation, system input or desktop capture")
        print("LIMIT: Live/full-screen flags and notifications are simulated on actual hidden windows; no physical border drag or Space transition was performed")
    }
}
