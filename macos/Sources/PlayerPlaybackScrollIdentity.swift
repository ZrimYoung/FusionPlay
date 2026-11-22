import AppKit
import SwiftUI

/// Put one marker in the persistent playback ScrollView's content background.
/// Only its real native ancestor receives this role; a neighbouring lyric
/// viewport must never be identified by its size or screen overlap.
struct PlayerPlaybackScrollIdentity: NSViewRepresentable {
    static let scrollIdentifier = NSUserInterfaceItemIdentifier("fusionplay.player.playback-scroll")

    final class MarkerView: NSView {
        private weak var markedScroll: NSScrollView?
        private var originalIdentifier: NSUserInterfaceItemIdentifier?
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview(); bindToAncestor()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); bindToAncestor()
        }
        override func layout() { super.layout(); bindToAncestor() }

        func bindToAncestor() {
            let ancestor = enclosingScrollView
            guard ancestor !== markedScroll else { return }
            unbind()
            guard let ancestor else { return }
            originalIdentifier = ancestor.identifier
            markedScroll = ancestor
            ancestor.identifier = PlayerPlaybackScrollIdentity.scrollIdentifier
        }
        func unbind() {
            if let markedScroll, markedScroll.identifier == PlayerPlaybackScrollIdentity.scrollIdentifier {
                markedScroll.identifier = originalIdentifier
            }
            markedScroll = nil; originalIdentifier = nil
        }
    }

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: MarkerView, context: Context) { view.bindToAncestor() }
    static func dismantleNSView(_ view: MarkerView, coordinator: ()) { view.unbind() }
}
