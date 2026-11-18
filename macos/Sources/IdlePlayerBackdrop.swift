import AppKit
import SwiftUI

/// A drawing-only background; native window geometry and corner clipping stay
/// with the player window rather than this representable.
struct IdlePlayerBackdrop: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.update(reduceTransparency: reduceTransparency)
        return view
    }
    func updateNSView(_ view: BackdropView, context: Context) {
        view.update(reduceTransparency: reduceTransparency)
    }

    final class BackdropView: NSView {
        private let material = NSVisualEffectView()
        private let fallback = WindowBackgroundView()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            material.appearance = NSAppearance(named: .vibrantDark)
            let surfaces: [NSView] = [material, fallback]
            for view in surfaces {
                view.frame = bounds
                view.autoresizingMask = [.width, .height]
                view.setAccessibilityElement(false)
                addSubview(view)
            }
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(reduceTransparency: Bool) {
            material.isHidden = reduceTransparency
            fallback.isHidden = !reduceTransparency
        }
    }

    private final class WindowBackgroundView: NSView {
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}
