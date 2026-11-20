import AppKit
import SwiftUI

/// A transparent geometry marker gives custom controls priority over mouse
/// paging even when SwiftUI has not materialized its accessibility tree.
struct PlayerPagingDragExclusion: NSViewRepresentable {
    var identifier = "fusionplay.player.paging-drag-exclusion"
    final class Region: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> NSView {
        let view = Region(); view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
