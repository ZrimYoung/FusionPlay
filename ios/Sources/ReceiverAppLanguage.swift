import Foundation
import SwiftUI

enum ReceiverAppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let storageKey = "receiverAppLanguage"
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    static func text(_ key: String.LocalizationValue) -> String {
        let preferred = UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .system
        if preferred != .system, let url = Bundle.main.url(forResource: preferred.rawValue, withExtension: "lproj"),
           let bundle = Bundle(url: url) {
            return String(localized: key, bundle: bundle)
        }
        return String(localized: key)
    }
}
