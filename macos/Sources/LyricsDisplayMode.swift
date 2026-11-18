import Foundation

enum LyricsDisplayMode: String, CaseIterable {
    case automatic, always, never

    static let storageKey = "playerLyricsDisplayMode"

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .always: return "始终开启"
        case .never: return "始终关闭"
        }
    }

    static func migrateLegacyPreference(in defaults: UserDefaults = .standard,
                                        legacyKey: String = "playerShowsLyrics") {
        guard defaults.object(forKey: storageKey) == nil,
              let legacy = defaults.object(forKey: legacyKey) as? Bool else { return }
        defaults.set((legacy ? Self.always : Self.never).rawValue, forKey: storageKey)
    }

    func isVisible(hasLyrics: Bool) -> Bool {
        switch self {
        case .automatic: return hasLyrics
        case .always: return true
        case .never: return false
        }
    }
}

/// Keep the current automatic layout while a replacement document is parsed.
/// A completed empty document or disconnect resolves immediately to hidden.
/// The caller clears `loading` and `hasLyrics` when the media session ends.
enum LyricsAutoVisibility {
    static func resolve(hasLyrics: Bool, loading: Bool, previouslyVisible: Bool) -> Bool {
        loading ? previouslyVisible : hasLyrics
    }
}
