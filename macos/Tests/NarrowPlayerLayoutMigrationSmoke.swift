import Foundation

private final class LayoutMemoryDefaults: UserDefaults {
    var values: [String: Any] = [:]
    var writes = 0
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value; writes += 1 }
}

@main struct NarrowPlayerLayoutMigrationSmoke {
    static func main() {
        for old in [false, true] {
            let defaults = LayoutMemoryDefaults()
            defaults.values = [NarrowPlayerLayout.legacyStorageKey: old, "unrelated": "kept"]
            NarrowPlayerLayout.migrateLegacyPreference(in: defaults)
            precondition(defaults.values[NarrowPlayerLayout.storageKey] as? String
                         == (old ? NarrowPlayerLayout.squarePaged.rawValue : NarrowPlayerLayout.original.rawValue))
            NarrowPlayerLayout.migrateLegacyPreference(in: defaults)
            precondition(defaults.writes == 1 && defaults.values["unrelated"] as? String == "kept")
            precondition(defaults.values[NarrowPlayerLayout.legacyStorageKey] as? Bool == old)
        }
        let fresh = LayoutMemoryDefaults()
        NarrowPlayerLayout.migrateLegacyPreference(in: fresh)
        precondition(fresh.values[NarrowPlayerLayout.storageKey] as? String == NarrowPlayerLayout.original.rawValue)
        for selected in ["original", "squarePaged", "ipadPaged", "future-mode", ""] {
            let defaults = LayoutMemoryDefaults()
            defaults.values = [NarrowPlayerLayout.storageKey: selected, NarrowPlayerLayout.legacyStorageKey: true]
            NarrowPlayerLayout.migrateLegacyPreference(in: defaults)
            precondition(defaults.writes == 0 && defaults.values[NarrowPlayerLayout.storageKey] as? String == selected)
        }
        precondition(NarrowPlayerLayout.resolve("future-mode") == .original)
        precondition(NarrowPlayerLayout.settingsChoices == [.squarePaged, .ipadPaged])
        precondition(NarrowPlayerLayout.original.settingsSelection == .squarePaged
                     && NarrowPlayerLayout.squarePaged.settingsSelection == .squarePaged
                     && NarrowPlayerLayout.ipadPaged.settingsSelection == .ipadPaged,
                     "Legacy cover states must map to a single cover style without rewriting saved state")
        print("PASS: fresh original default, legacy Bool mapping to original/square, one-time migration and explicit/future selection preservation; in-memory defaults only")
    }
}
