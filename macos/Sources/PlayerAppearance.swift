import AppKit
import SwiftUI

enum ProgressColorMode: String, CaseIterable {
    case white, system, custom
    var title: String {
        switch self { case .white: return "白色"; case .system: return "跟随系统"; case .custom: return "自定义" }
    }
}

struct PlayerAppearance {
    static let defaultCustomHex = "#0A84FF"
    static func color(mode: String, hex: String) -> Color {
        switch ProgressColorMode(rawValue: mode) ?? .white {
        case .white: return .white
        case .system: return Color(nsColor: .controlAccentColor)
        case .custom: return Color(nsColor: nsColor(hex: hex))
        }
    }
    static func nsColor(hex: String) -> NSColor {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nsColor(hex: defaultCustomHex) }
        return NSColor(srgbRed: CGFloat((number >> 16) & 255) / 255,
                       green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
    static func hex(_ color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return defaultCustomHex }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    static func time(_ milliseconds: UInt64?) -> String {
        guard let milliseconds else { return "–:––" }
        let seconds = milliseconds / 1000
        if seconds >= 3600 { return String(format: "%llu:%02llu:%02llu", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%llu:%02llu", seconds / 60, seconds % 60)
    }
}
