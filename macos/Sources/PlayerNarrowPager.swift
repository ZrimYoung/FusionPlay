import AppKit
import SwiftUI

/// Both pages stay mounted so changing pages preserves the lyric reading state.
struct PlayerNarrowPager<Playback: View, Lyrics: View>: View {
    @Binding var selection: CompactPlayerPage
    let requestPage: (CompactPlayerPage) -> Void
    var pagingEnabled = true
    @ViewBuilder let playback: () -> Playback
    @ViewBuilder let lyrics: () -> Lyrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTypography) private var typography

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let page = pagingEnabled ? selection : .playback
            HStack(spacing: 0) {
                playback().frame(width: width, height: geometry.size.height)
                    .allowsHitTesting(page == .playback).accessibilityHidden(page != .playback)
                lyrics().frame(width: width, height: geometry.size.height)
                    .allowsHitTesting(page == .lyrics).accessibilityHidden(page != .lyrics)
            }
            .offset(x: page == .playback ? 0 : -width)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: selection)
        }.clipped()
            // Measure the visible viewport, not the translated two-page strip.
            .background { NarrowPlayerHorizontalScroll(requestPage: requestPage, enabled: pagingEnabled) }
    }
}

struct NarrowPlayerHorizontalScroll: NSViewRepresentable {
    let requestPage: (CompactPlayerPage) -> Void
    var enabled = true
    private final class PagingRegionView: NSView {
        var movedToWindow: (() -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); movedToWindow?() }
        // The monitor observes the app's events; its transparent measuring view
        // must never intercept buttons, text selection or native scroll input.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        weak var view: NSView?
        var requestPage: (CompactPlayerPage) -> Void = { _ in }
        var monitor: Any?
        var gesture = NarrowPlayerSwipeState()
        var lastTime: TimeInterval = 0
        var horizontalMomentum = false
        private weak var dragHost: NSView?
        private var drag: NSPanGestureRecognizer?
        private var dragTurned = false
        private(set) var enabled = true

        func setEnabled(_ enabled: Bool) {
            guard self.enabled != enabled else { return }
            self.enabled = enabled
            gesture.reset(); horizontalMomentum = false; lastTime = 0; dragTurned = false
            drag?.isEnabled = enabled
        }
        func installDrag() {
            guard let host = view?.window?.contentView, dragHost !== host else { return }
            if let drag { dragHost?.removeGestureRecognizer(drag) }
            let recognizer = NSPanGestureRecognizer(target: self, action: #selector(didDrag(_:)))
            recognizer.delegate = self
            recognizer.delaysPrimaryMouseButtonEvents = true
            recognizer.isEnabled = enabled
            host.addGestureRecognizer(recognizer)
            dragHost = host; drag = recognizer
        }
        func gestureRecognizer(_ recognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
            guard enabled, let view, let window = view.window, event.window === window,
                  !view.isHiddenOrHasHiddenAncestor,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return false }
            // The native titlebar remains available for moving the window.
            let point = view.convert(event.locationInWindow, from: nil)
            let fromTop = view.isFlipped ? point.y - view.bounds.minY : view.bounds.maxY - point.y
            guard fromTop > 44 else { return false }
            if let root = window.contentView, excludesDrag(root, windowPoint: event.locationInWindow) { return false }
            // Mouse drags on controls and selectable song/lyric text keep their
            // existing meaning. Trackpad paging still works over that content.
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            var node = window.contentView?.accessibilityHitTest(screenPoint) as? NSObject
            let excludedRoles = [NSAccessibility.Role.button, .slider, .textField, .textArea, .staticText,
                                 .link, .scrollBar, .popUpButton, .menuButton, .splitter].map(\.rawValue)
            for _ in 0..<8 {
                guard let current = node else { break }
                // SwiftUI's virtual elements can implement the public AX methods
                // without formally conforming to NSAccessibilityProtocol.
                if let frame = (accessibilityAttribute(current, "accessibilityFrame") as? NSValue)?.rectValue,
                   frame.contains(screenPoint) {
                    if let identifier = accessibilityAttribute(current, "accessibilityIdentifier") as? String,
                       ["fusionplay.player.progress", "fusionplay.player.paged-progress",
                        "fusionplay.player.cover-lyrics-resize"].contains(identifier) { return false }
                    if let role = accessibilityAttribute(current, "accessibilityRole") as? String,
                       excludedRoles.contains(role) { return false }
                }
                node = accessibilityAttribute(current, "accessibilityParent") as? NSObject
            }
            dragTurned = false
            return true
        }
        private func excludesDrag(_ view: NSView, windowPoint: NSPoint) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if view is PlayerPagingDragExclusion.Region
                || view.identifier?.rawValue == "fusionplay.player.cover-lyrics-resize" {
                if view.bounds.width > 0, view.bounds.height > 0,
                   view.bounds.contains(view.convert(windowPoint, from: nil)) { return true }
            }
            return view.subviews.contains { excludesDrag($0, windowPoint: windowPoint) }
        }
        private func accessibilityAttribute(_ object: NSObject, _ key: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(key)) else { return nil }
            return object.value(forKey: key)
        }
        func gestureRecognizerShouldBegin(_ recognizer: NSGestureRecognizer) -> Bool {
            guard enabled, let pan = recognizer as? NSPanGestureRecognizer else { return false }
            let translation = pan.translation(in: dragHost)
            return abs(translation.x) > abs(translation.y) * 1.35
        }
        @objc private func didDrag(_ recognizer: NSPanGestureRecognizer) {
            guard enabled, !dragTurned, recognizer.state == .began || recognizer.state == .changed || recognizer.state == .ended else { return }
            let translation = recognizer.translation(in: dragHost)
            guard abs(translation.x) >= 48 else { return }
            dragTurned = true
            requestPage(translation.x < 0 ? .lyrics : .playback)
        }
        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleWheel(event) == true ? nil : event
            }
        }
        func handleWheel(_ event: NSEvent) -> Bool {
            guard enabled else { return false }
            var handled = false
            MainActor.assumeIsolated {
                guard let view = self.view, !view.isHiddenOrHasHiddenAncestor,
                      let window = view.window, event.window === window,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return }
                if event.phase.contains(.began) || (event.phase.isEmpty && event.momentumPhase.isEmpty && event.timestamp - self.lastTime > 0.25) {
                    self.gesture.reset(); self.horizontalMomentum = false
                }
                self.lastTime = event.timestamp
                if !event.momentumPhase.isEmpty {
                    handled = self.horizontalMomentum
                    if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { self.horizontalMomentum = false }
                    return
                }
                let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                if let page = self.gesture.consume(x: event.scrollingDeltaX * unit, y: event.scrollingDeltaY * unit) { self.requestPage(page) }
                // Once horizontal intent is established, do not leak the
                // rest of that paging gesture into a vertical scroll view.
                handled = self.gesture.hasHorizontalIntent
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    self.horizontalMomentum = handled && !event.phase.contains(.cancelled)
                    self.gesture.reset()
                }
            }
            return handled
        }
        func dismantle() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let drag { dragHost?.removeGestureRecognizer(drag) }
            monitor = nil; drag = nil; dragHost = nil; view = nil
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = PagingRegionView()
        view.identifier = NSUserInterfaceItemIdentifier("fusionplay.player.horizontal-paging-region")
        context.coordinator.view = view
        context.coordinator.requestPage = requestPage
        context.coordinator.setEnabled(enabled); context.coordinator.install()
        view.movedToWindow = { [weak coordinator = context.coordinator] in coordinator?.installDrag() }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.requestPage = requestPage
        context.coordinator.setEnabled(enabled); context.coordinator.installDrag()
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.dismantle() }
}
