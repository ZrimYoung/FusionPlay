import AppKit
import SwiftUI

/// Both pages stay mounted so changing pages preserves the lyric reading state.
struct PlayerNarrowPager<Playback: View, Lyrics: View>: View {
    @Binding var selection: CompactPlayerPage
    let requestPage: (CompactPlayerPage) -> Void
    @ViewBuilder let playback: () -> Playback
    @ViewBuilder let lyrics: () -> Lyrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appTypography) private var typography

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                playback().frame(width: width, height: geometry.size.height)
                    .allowsHitTesting(selection == .playback).accessibilityHidden(selection != .playback)
                lyrics().frame(width: width, height: geometry.size.height)
                    .allowsHitTesting(selection == .lyrics).accessibilityHidden(selection != .lyrics)
            }
            .offset(x: selection == .playback ? 0 : -width)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: selection)
            .background { NarrowPlayerHorizontalScroll(requestPage: requestPage) }
        }.clipped()
    }
}

private struct NarrowPlayerHorizontalScroll: NSViewRepresentable {
    let requestPage: (CompactPlayerPage) -> Void
    private final class PagingRegionView: NSView {
        // The monitor observes the app's events; its transparent measuring view
        // must never intercept buttons, text selection or native scroll input.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    final class Coordinator {
        weak var view: NSView?
        var requestPage: (CompactPlayerPage) -> Void = { _ in }
        var monitor: Any?
        var gesture = NarrowPlayerSwipeState()
        var lastTime: TimeInterval = 0
        var horizontalMomentum = false
        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                var handled = false
                MainActor.assumeIsolated {
                    guard let self, let view = self.view, !view.isHiddenOrHasHiddenAncestor,
                          let window = view.window, event.window === window,
                          event.hasPreciseScrollingDeltas,
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
                    if let page = self.gesture.consume(x: event.scrollingDeltaX, y: event.scrollingDeltaY) { self.requestPage(page) }
                    // Once horizontal intent is established, do not leak the
                    // rest of that paging gesture into a vertical scroll view.
                    handled = self.gesture.hasHorizontalIntent
                    if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                        self.horizontalMomentum = handled && !event.phase.contains(.cancelled)
                        self.gesture.reset()
                    }
                }
                return handled ? nil : event
            }
        }
        func dismantle() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; view = nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = PagingRegionView()
        view.identifier = NSUserInterfaceItemIdentifier("fusionplay.player.horizontal-paging-region")
        context.coordinator.view = view
        context.coordinator.requestPage = requestPage; context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.requestPage = requestPage }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.dismantle() }
}
