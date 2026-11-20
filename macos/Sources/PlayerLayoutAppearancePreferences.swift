import Foundation

/// Layout-specific display preferences fall back to the original shared keys
/// until the user changes that mode. Reading a mode never migrates any data.
enum PlayerLayoutFamily: String, CaseIterable {
    case cover, album

    init(layout: NarrowPlayerLayout) { self = layout.isCover ? .cover : .album }
    var title: String { self == .cover ? "封面模式" : "专辑模式" }
    var transportKey: String { self == .cover ? "coverPlayerShowsTransport" : "albumPlayerShowsTransport" }
    var progressKey: String { self == .cover ? "coverPlayerShowsProgress" : "albumPlayerShowsProgress" }
    var layoutSelection: NarrowPlayerLayout { self == .cover ? .original : .ipadPaged }
}
