import Foundation

/// Stable preferences distinguish the legacy stack, square cover paging, and
/// the independent playback column. All three use the same current-track state.
enum NarrowPlayerLayout: String, CaseIterable, Sendable {
    case original, squarePaged, ipadPaged
    static let storageKey = "narrowPlayerLayout"
    static let legacyStorageKey = "narrowPlayerPaging"
    var isPaged: Bool { self != .original }
    var title: String {
        switch self {
        case .original: return "原有布局"
        case .squarePaged: return "方形分页"
        case .ipadPaged: return "独立播放页"
        }
    }
    static func resolve(_ rawValue: String) -> Self { Self(rawValue: rawValue) ?? .original }
    static func migrateLegacyPreference(in defaults: UserDefaults = .standard) {
        // Presence, rather than recognized value, protects explicit selections
        // and settings made by a newer application version.
        guard defaults.object(forKey: storageKey) == nil else { return }
        let legacy = defaults.object(forKey: legacyStorageKey) as? Bool ?? false
        defaults.set((legacy ? Self.squarePaged : Self.original).rawValue, forKey: storageKey)
    }
}
