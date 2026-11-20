import Foundation

/// All preference reads/writes stay in memory, including migration writes.
private final class MemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

@main struct LyricsDisplayModeSmoke {
    static func main() {
        let preferences = MemoryDefaults()
        let key = LyricsDisplayMode.storageKey
        LyricsDisplayMode.migrateLegacyPreference(in: preferences)
        precondition(preferences.object(forKey: key) == nil,
                     "A new installation must keep the automatic default")
        for legacy in [false, true] {
            preferences.values = ["playerShowsLyrics": legacy, "unrelated": "preserved"]
            LyricsDisplayMode.migrateLegacyPreference(in: preferences)
            let expected: LyricsDisplayMode = legacy ? .automatic : .never
            precondition(preferences.object(forKey: key) as? String == expected.rawValue)
            precondition(preferences.object(forKey: "playerShowsLyrics") as? Bool == legacy)
            precondition(preferences.object(forKey: "unrelated") as? String == "preserved")
            // Reopening must not replace a user's newer selection with the old switch.
            preferences.set(LyricsDisplayMode.automatic.rawValue, forKey: key)
            LyricsDisplayMode.migrateLegacyPreference(in: preferences)
            precondition(preferences.object(forKey: key) as? String == "automatic")
        }
        preferences.values = [key: "always", "unrelated": "preserved"]
        LyricsDisplayMode.migrateLegacyPreference(in: preferences)
        precondition(preferences.object(forKey: key) as? String == "automatic")
        precondition(preferences.object(forKey: "unrelated") as? String == "preserved")
        precondition(LyricsDisplayMode.allCases == [.automatic, .never])
        preferences.values = [key: "future-value", "playerShowsLyrics": true]
        LyricsDisplayMode.migrateLegacyPreference(in: preferences)
        precondition(preferences.object(forKey: key) as? String == "future-value")
        for hasLyrics in [false, true] {
            precondition(LyricsDisplayMode.automatic.isVisible(hasLyrics: hasLyrics) == hasLyrics)
            precondition(!LyricsDisplayMode.never.isVisible(hasLyrics: hasLyrics))
        }
        var visible = false
        func receive(_ hasLyrics: Bool, loading: Bool) {
            visible = LyricsAutoVisibility.resolve(hasLyrics: hasLyrics, loading: loading,
                                                    previouslyVisible: visible)
        }
        receive(false, loading: true)
        precondition(!visible, "Late lyrics should not expose an empty pane while parsing")
        receive(true, loading: false)
        precondition(visible, "Late lyrics must appear once a displayable document arrives")
        receive(false, loading: true)
        precondition(visible, "Track replacement parsing must not briefly collapse the lyric layout")
        receive(true, loading: false)
        precondition(visible)
        receive(false, loading: false)
        precondition(!visible, "A track without lyrics must close the automatic pane")
        receive(true, loading: false)
        receive(false, loading: false)
        precondition(!visible, "Disconnect must clear the automatic layout")
        // LyricsAvailability must be based on displayable content, not a nonempty LRC header.
        for source in ["", "[ti:Preview]\n[ar:FusionPlay]", "[00:01.00]\n[00:03.00]"] {
            let document = LyricsDocument(source)
            receive(!document.lines.isEmpty, loading: false)
            precondition(!visible)
        }
        for source in ["A quiet morning", "[00:01.00]A quiet morning\n[00:03.00]"] {
            let document = LyricsDocument(source)
            receive(!document.lines.isEmpty, loading: false)
            precondition(visible, "Both timed and untimed lyrics should trigger automatic display")
        }
        print("PASS: lyrics modes, legacy preference preservation, late lyrics, parsing stability, empty tracks and disconnects")
        print("Preference tests used in-memory defaults; no application settings were changed")
    }
}
