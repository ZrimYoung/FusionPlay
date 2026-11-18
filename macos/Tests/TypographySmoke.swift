import AppKit
import CoreText
import SwiftUI

@main struct TypographySmoke {
    static func main() {
        precondition(Thread.isMainThread)
        let standard = AppTypography()
        precondition(standard.family.isEmpty && standard.weight == 400 && !standard.isMissing)
        let semantics: [(Font.Weight, NSFont.Weight)] = [
            (.ultraLight, .ultraLight), (.thin, .thin), (.light, .light), (.regular, .regular),
            (.medium, .medium), (.semibold, .semibold), (.bold, .bold), (.heavy, .heavy), (.black, .black)
        ]
        for (semantic, native) in semantics {
            let resolved = standard.nsFont(size: 19, weight: semantic)
            precondition(resolved == NSFont.systemFont(ofSize: 19, weight: native),
                         "Default system typography must preserve every semantic weight and size")
        }
        precondition(FontCatalog.nearestWeight(in: [700, 300], to: 500) == 300)
        precondition(FontCatalog.nearestWeight(in: [100, 400, 900], to: 620) == 400)
        precondition(FontCatalog.nearestWeight(in: [], to: 600) == 400)
        precondition(FontCatalog.nearestWeight(in: [0, 1000], to: 600) == 400)
        let missingName = "FusionPlay-Missing-Font-5FB471C8"
        let missing = AppTypography(family: missingName)
        precondition(missing.family == missingName && missing.isMissing)
        precondition(missing.availableWeights == Array(stride(from: 100, through: 900, by: 100)))
        precondition(missing.nsFont(size: 25, weight: .bold) == NSFont.systemFont(ofSize: 25, weight: .bold))
        precondition(AppTypography(weight: 600).nsFont(size: 22, weight: .semibold)
                     == NSFont.systemFont(ofSize: 22, weight: .heavy))
        precondition(AppTypography(weight: 900).nsFont(size: 22, weight: .bold)
                     == NSFont.systemFont(ofSize: 22, weight: .black))
        precondition(AppTypography(weight: 100).nsFont(size: 22, weight: .light)
                     == NSFont.systemFont(ofSize: 22, weight: .ultraLight))
        precondition(AppTypography(weight: -10).weight == 100 && AppTypography(weight: 1000).weight == 900)

        let families = FontCatalog.installedFamilies
        precondition(!families.isEmpty && Set(families.map(\.name)).count == families.count)
        for family in families {
            precondition(!family.label.isEmpty && !family.weights.isEmpty)
            precondition(family.weights == Array(Set(family.weights)).sorted())
            precondition(family.weights.allSatisfy { (100...900).contains($0) })
        }
        let selected = families.first { $0.name == "Helvetica Neue" }
            ?? families.first { $0.weights.count >= 3 } ?? families[0]
        let members = NSFontManager.shared.availableMembers(ofFontFamily: selected.name) ?? []
        let postScriptNames = Set(members.compactMap { $0.first as? String })
        let hasUpright = postScriptNames.contains { name in
            let font = CTFontCreateWithName(name as CFString, 19, nil)
            return !CTFontGetSymbolicTraits(font).contains(.traitItalic)
        }
        for weight in selected.weights {
            let typography = AppTypography(family: selected.name, weight: weight)
            let font = typography.nsFont(size: 19)
            precondition(!typography.isMissing && typography.availableWeights == selected.weights)
            precondition(font.pointSize == 19 && postScriptNames.contains(font.fontName),
                         "Custom typography must select a real installed face in the selected family")
            if hasUpright {
                let native = CTFontCreateWithName(font.fontName as CFString, 19, nil)
                precondition(!CTFontGetSymbolicTraits(native).contains(.traitItalic), "Prefer upright font faces")
            }
            precondition(font === typography.nsFont(size: 19), "Resolved fonts should reuse the cache")
        }
        if selected.name == "Helvetica Neue" {
            precondition(selected.weights.contains(400) && selected.weights.contains(700),
                         "Normalized regular and bold faces must map to CSS 400 and 700")
            precondition(AppTypography(family: selected.name).nsFont(size: 19).fontName == "HelveticaNeue")
            precondition(AppTypography(family: selected.name).nsFont(size: 19, weight: .bold).fontName == "HelveticaNeue-Bold")
        }
        let defaultEnvironment = EnvironmentValues()
        precondition(defaultEnvironment.appTypography == standard)
        _ = standard.font(size: 13)
        print("PASS: default semantic weights, missing-family preservation/fallback, nearest weights and bounds")
        print("PASS: \(families.count) installed font families, actual upright faces and cached resolution (\(selected.name))")
        print("Typography checks did not read or write application preferences")
    }
}
