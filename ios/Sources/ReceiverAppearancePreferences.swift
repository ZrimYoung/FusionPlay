import SwiftUI
import UIKit

enum ReceiverProgressColorMode: String, CaseIterable, Identifiable {
    case white, system, custom

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .white: "白色"
        case .system: "跟随系统"
        case .custom: "自定义"
        }
    }
}

enum ReceiverProgressAppearance {
    static let modeKey = "playerProgressColorMode"
    static let customColorKey = "playerCustomProgressHex"
    static let defaultCustomHex = "#0A84FF"

    static func fill(mode: ReceiverProgressColorMode, customHex: String) -> Color {
        switch mode {
        case .white: .white
        case .system: .accentColor
        case .custom: color(from: customHex)
        }
    }

    static func color(from hex: String) -> Color {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        let rgb = digits.count == 6 ? UInt32(digits, radix: 16) : nil
        let value = rgb ?? 0x0A84FF
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    static func hex(from color: Color) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: nil),
              [red, green, blue].allSatisfy(\.isFinite) else { return nil }
        let channels = [red, green, blue].map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}

struct LyricsShadowAppearance {
    static let enabledKey = "lyricShadowEnabled"
    static let opacityKey = "lyricShadowOpacityPercent"
    static let spreadKey = "lyricShadowSpreadPoints"
    static let opacityRange = 0...100
    static let spreadRange = 0...24
    static let defaultOpacity = 45
    static let defaultSpread = 8

    let opacity: Double
    let radius: CGFloat

    init(enabled: Bool, opacityPercent: Int, spread: Int) {
        opacity = enabled ? Double(Self.clamp(opacityPercent, to: Self.opacityRange)) / 100 : 0
        radius = opacity > 0 ? CGFloat(Self.clamp(spread, to: Self.spreadRange)) : 0
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }
}

struct ReceiverTypography: Equatable {
    static let familyKey = "uiFontFamily"
    static let faceKey = "uiFontFace"

    let face: String?

    init(face: String = "") {
        self.face = !face.isEmpty && UIFont(name: face, size: 17) != nil ? face : nil
    }

    func font(size: CGFloat, weight: Font.Weight) -> Font {
        guard let face else { return .system(size: size, weight: weight) }
        // Lyrics already scale their measured sizes with Dynamic Type.
        return .custom(face, fixedSize: size)
    }

    func font(_ style: Font.TextStyle, size: CGFloat, weight: Font.Weight) -> Font {
        guard let face else { return .system(style, weight: weight) }
        return .custom(face, size: size, relativeTo: style)
    }
}

private struct ReceiverTypographyKey: EnvironmentKey {
    static let defaultValue = ReceiverTypography()
}

extension EnvironmentValues {
    var receiverTypography: ReceiverTypography {
        get { self[ReceiverTypographyKey.self] }
        set { self[ReceiverTypographyKey.self] = newValue }
    }
}

private struct ReceiverTypographyModifier: ViewModifier {
    @AppStorage(ReceiverTypography.faceKey) private var face = ""

    func body(content: Content) -> some View {
        content.environment(\.receiverTypography, ReceiverTypography(face: face))
    }
}

extension View {
    func receiverTypography() -> some View {
        modifier(ReceiverTypographyModifier())
    }
}
