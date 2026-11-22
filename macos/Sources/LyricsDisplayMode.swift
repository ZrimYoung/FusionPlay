import Foundation

enum LyricsDisplayMode: String, CaseIterable {
    case automatic
#if os(iOS)
    case always
#endif
    case never

    static let storageKey = "playerLyricsDisplayMode"

    var title: String {
        switch self {
#if os(iOS)
        case .automatic: return "自动"
        case .always: return "始终开启"
#else
        case .automatic: return "自动开启"
#endif
        case .never: return "始终关闭"
        }
    }

    static func migrateLegacyPreference(in defaults: UserDefaults = .standard,
                                        legacyKey: String = "playerShowsLyrics") {
        if let stored = defaults.object(forKey: storageKey) {
#if !os(iOS)
            if stored as? String == "always" { defaults.set(Self.automatic.rawValue, forKey: storageKey) }
#endif
            return
        }
        guard let legacy = defaults.object(forKey: legacyKey) as? Bool else { return }
#if os(iOS)
        defaults.set((legacy ? Self.always : Self.never).rawValue, forKey: storageKey)
#else
        defaults.set((legacy ? Self.automatic : Self.never).rawValue, forKey: storageKey)
#endif
    }

    func isVisible(hasLyrics: Bool) -> Bool {
        switch self {
        case .automatic: return hasLyrics
#if os(iOS)
        case .always: return true
#endif
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
