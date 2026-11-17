import AppKit
import CoreText
import SwiftUI

struct FontFamilyChoice: Identifiable, Equatable {
    let name: String
    let label: String
    let weights: [Int]
    var id: String { name }
}

/// The catalog and resolved fonts are cached for use by views on the main thread.
/// PostScript faces, rather than the font manager's legacy 0...15 weights, are
/// resolved through Core Text's normalized weight trait.
enum FontCatalog {
    private struct Face {
        let postScriptName: String
        let weight: Int
        let italic: Bool
    }
    private struct FontKey: Hashable {
        let family: String
        let weight: Int
        let size: CGFloat
    }
    private static let systemWeights = Array(stride(from: 100, through: 900, by: 100))
    private static let weightSteps: [(css: Int, native: NSFont.Weight)] = [
        (100, .ultraLight), (200, .thin), (300, .light), (400, .regular),
        (500, .medium), (600, .semibold), (700, .bold), (800, .heavy), (900, .black)
    ]
    private static let familyNames = NSFontManager.shared.availableFontFamilies
    private static let familyLookup: [String: String] = Dictionary(
        familyNames.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first }
    )
    private static var facesByFamily: [String: [Face]] = [:]
    private static var fonts: [FontKey: NSFont] = [:]

    static let installedFamilies: [FontFamilyChoice] = familyNames.map { name in
        FontFamilyChoice(name: name,
                         label: NSFontManager.shared.localizedName(forFamily: name, face: nil),
                         weights: availableWeights(for: name))
    }.sorted {
        let comparison = $0.label.localizedStandardCompare($1.label)
        return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
    }

    static func availableWeights(for family: String) -> [Int] {
        guard let installed = installedFamily(family) else { return systemWeights }
        let weights = Array(Set(faces(for: installed).map(\.weight))).sorted()
        return weights.isEmpty ? systemWeights : weights
    }

    static func nearestWeight(in available: [Int], to requested: Int) -> Int {
        let target = min(900, max(100, requested))
        return available.filter { (100...900).contains($0) }.min {
            let left = abs($0 - target), right = abs($1 - target)
            return left == right ? $0 < $1 : left < right
        } ?? AppTypography.defaultWeight
    }

    fileprivate static func installedFamily(_ family: String) -> String? {
        guard !family.isEmpty else { return nil }
        return familyLookup[family.lowercased()]
    }

    fileprivate static func resolvedFont(family: String, weight: Int, size: CGFloat) -> NSFont {
        let installed = installedFamily(family)
        let key = FontKey(family: installed ?? "", weight: weight, size: size)
        if let cached = fonts[key] { return cached }
        let result: NSFont
        if let installed, let face = nearestFace(in: faces(for: installed), to: weight),
           let font = NSFont(name: face.postScriptName, size: size) {
            result = font
        } else {
            let resolvedWeight = nearestWeight(in: systemWeights, to: weight)
            let native = weightSteps.first { $0.css == resolvedWeight }?.native ?? .regular
            result = NSFont.systemFont(ofSize: size, weight: native)
        }
        // Lyrics use continuously varying sizes during live window resizing.
        // Keep this process-local optimization bounded across sizes/families.
        if fonts.count >= 512 { fonts.removeAll(keepingCapacity: true) }
        fonts[key] = result
        return result
    }

    private static func faces(for family: String) -> [Face] {
        if let cached = facesByFamily[family] { return cached }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        var seen = Set<String>()
        let faces: [Face] = members.compactMap { member in
            guard let name = member.first as? String, seen.insert(name).inserted,
                  let font = NSFont(name: name, size: 13) else { return nil }
            let native = CTFontCreateWithName(font.fontName as CFString, 13, nil)
            let traits = CTFontCopyTraits(native) as NSDictionary
            let normalized = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let weight = weightSteps.min {
                let left = abs(Double($0.native.rawValue) - normalized)
                let right = abs(Double($1.native.rawValue) - normalized)
                return left == right ? $0.css < $1.css : left < right
            }?.css ?? AppTypography.defaultWeight
            return Face(postScriptName: font.fontName, weight: weight,
                        italic: CTFontGetSymbolicTraits(native).contains(.traitItalic))
        }
        let upright = faces.filter { !$0.italic }
        let preferred = (upright.isEmpty ? faces : upright).sorted {
            $0.weight == $1.weight ? $0.postScriptName < $1.postScriptName : $0.weight < $1.weight
        }
        facesByFamily[family] = preferred
        return preferred
    }

    private static func nearestFace(in faces: [Face], to requested: Int) -> Face? {
        let weight = nearestWeight(in: faces.map(\.weight), to: requested)
        return faces.first { $0.weight == weight }
    }
}

struct AppTypography: Equatable {
    static let defaultWeight = 400
    let family: String
    let weight: Int

    init(family: String = "", weight: Int = defaultWeight) {
        self.family = family
        self.weight = min(900, max(100, weight))
    }

    var isMissing: Bool { !family.isEmpty && FontCatalog.installedFamily(family) == nil }
    var availableWeights: [Int] { FontCatalog.availableWeights(for: family) }

    func font(size: CGFloat, weight semanticWeight: Font.Weight = .regular) -> Font {
        Font(nsFont(size: size, weight: semanticWeight))
    }

    func nsFont(size: CGFloat, weight semanticWeight: Font.Weight = .regular) -> NSFont {
        let offset: Int
        switch semanticWeight {
        case .ultraLight: offset = -300
        case .thin: offset = -200
        case .light: offset = -100
        case .medium: offset = 100
        case .semibold: offset = 200
        case .bold: offset = 300
        case .heavy: offset = 400
        case .black: offset = 500
        default: offset = 0
        }
        return FontCatalog.resolvedFont(family: family, weight: min(900, max(100, weight + offset)), size: size)
    }
}

private struct AppTypographyKey: EnvironmentKey {
    static let defaultValue = AppTypography()
}

extension EnvironmentValues {
    var appTypography: AppTypography {
        get { self[AppTypographyKey.self] }
        set { self[AppTypographyKey.self] = newValue }
    }
}

private struct AppTypographyModifier: ViewModifier {
    @AppStorage("uiFontFamily") private var family = ""
    @AppStorage("uiFontWeight") private var weight = AppTypography.defaultWeight

    func body(content: Content) -> some View {
        let typography = AppTypography(family: family, weight: weight)
        content.environment(\.appTypography, typography)
            .font(typography.font(size: 13))
    }
}

extension View {
    func appTypography() -> some View { modifier(AppTypographyModifier()) }
}
