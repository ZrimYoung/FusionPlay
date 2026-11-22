import AppKit
import SwiftUI

/// Native transport input stays independent of the animated canvas geometry.
/// The surrounding SwiftUI view owns glass, opacity and placement.
struct PlayerTransportButton: NSViewRepresentable {
    let symbol: String
    let label: String
    let enabled: Bool
    let interactive: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> TransportButton {
        let button = TransportButton()
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.focusRingType = .none
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentHuggingPriority(.defaultLow, for: .vertical)
        button.target = context.coordinator
        button.action = #selector(Coordinator.invoke(_:))
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: TransportButton, context: Context) {
        context.coordinator.action = action
        button.interactive = interactive
        button.isEnabled = enabled && environmentEnabled
        if context.coordinator.symbol != symbol {
            context.coordinator.symbol = symbol
            button.image = Self.image(for: symbol)
        }
        if context.coordinator.label != label {
            context.coordinator.label = label
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        button.setAccessibilityIdentifier("fusionplay.player.transport." + Self.role(for: symbol))
        button.setAccessibilityElement(interactive)
        if !button.isEnabled || !interactive { button.highlight(false) }
    }
    static func dismantleNSView(_ button: TransportButton, coordinator: Coordinator) {
        button.interactive = false
        button.target = nil; button.action = nil
        coordinator.action = {}
    }

    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
    private static let symbols: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 16; return cache
    }()
    private static func image(for symbol: String) -> NSImage? {
        if let cached = symbols.object(forKey: symbol as NSString) { return cached }
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfiguration) else { return nil }
        image.isTemplate = true
        symbols.setObject(image, forKey: symbol as NSString)
        return image
    }
    private static func role(for symbol: String) -> String {
        switch symbol {
        case "backward.end.fill": return "previous"
        case "forward.end.fill": return "next"
        default: return "playPause"
        }
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        var symbol: String?
        var label: String?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke(_ sender: TransportButton) {
            guard sender.isEnabled, sender.interactive else { return }
            action()
        }
    }
    final class TransportButton: NSButton {
        var interactive = false
        override var acceptsFirstResponder: Bool { interactive && isEnabled }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard interactive, isEnabled else { return nil }
            return super.hitTest(point)
        }
        override func highlight(_ flag: Bool) {
            super.highlight(flag)
            alphaValue = flag && interactive && isEnabled ? 0.65 : 1
        }
        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad])
            if interactive, isEnabled, event.charactersIgnoringModifiers == " ", modifiers.isEmpty {
                performClick(nil)
            } else { super.keyDown(with: event) }
        }
    }
}
