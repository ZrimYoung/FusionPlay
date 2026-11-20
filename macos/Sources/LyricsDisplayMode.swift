import Foundation

enum LyricsDisplayMode: String, CaseIterable {
    case automatic, never

    static let storageKey = "playerLyricsDisplayMode"

    var title: String {
        switch self {
        case .automatic: return "自动开启"
        case .never: return "始终关闭"
        }
    }

    static func migrateLegacyPreference(in defaults: UserDefaults = .standard) {
        if let stored = defaults.object(forKey: storageKey) {
            if stored as? String == "always" { defaults.set(Self.automatic.rawValue, forKey: storageKey) }
            return
        }
        guard let legacy = defaults.object(forKey: "playerShowsLyrics") as? Bool else { return }
        defaults.set((legacy ? Self.automatic : Self.never).rawValue, forKey: storageKey)
    }

    func isVisible(hasLyrics: Bool) -> Bool {
        switch self {
        case .automatic: return hasLyrics
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
