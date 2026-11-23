import AppKit

enum MenuPanelBackgroundStyle: String, CaseIterable {
    case frosted
    case regularGlass = "regular"
    // Keep the old explicit clear selection stable; only an unset preference
    // adopts the new regular-glass default.
    case liquidGlass = "liquid"

    static let storageKey = "menuPanelBackgroundStyle"
    static var supportsLiquidGlass: Bool {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
#endif
        return false
    }
    static var defaultValue: Self { supportsLiquidGlass ? .regularGlass : .frosted }
    static var choices: [Self] { supportsLiquidGlass ? [.frosted, .regularGlass, .liquidGlass] : [.frosted] }
    static func resolve(_ value: String) -> Self {
        let selected = Self(rawValue: value) ?? defaultValue
        return selected != .frosted && !supportsLiquidGlass ? .frosted : selected
    }
    var title: String {
        switch self {
        case .frosted: return "磨砂玻璃"
        case .regularGlass: return "液态玻璃（默认）"
        case .liquidGlass: return "液态玻璃（通透）"
        }
    }
}
