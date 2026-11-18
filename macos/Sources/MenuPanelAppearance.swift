import AppKit

enum MenuPanelBackgroundStyle: String, CaseIterable {
    case frosted
    case liquidGlass = "liquid"

    static let storageKey = "menuPanelBackgroundStyle"
    static var supportsLiquidGlass: Bool {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
#endif
        return false
    }
    static var defaultValue: Self { supportsLiquidGlass ? .liquidGlass : .frosted }
    static var choices: [Self] { supportsLiquidGlass ? [.frosted, .liquidGlass] : [.frosted] }
    static func resolve(_ value: String) -> Self {
        let selected = Self(rawValue: value) ?? defaultValue
        return selected == .liquidGlass && !supportsLiquidGlass ? .frosted : selected
    }
    var title: String {
        switch self {
        case .frosted: return "毛玻璃"
        case .liquidGlass: return "清透液态玻璃"
        }
    }
}
