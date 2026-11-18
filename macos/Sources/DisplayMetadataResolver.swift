/// Display-only metadata. Playback and seek controls still use the transport snapshot.
struct DisplayMetadata: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
}

extension DisplayMetadata {
    init(_ state: Snapshot, correctLyricTitles: Bool) {
        // Nil means the SDK left a field unchanged. Preserve an explicit empty
        // string so a confirmed lyric can use the existing unknown-title UI.
        self.init(
            title: (correctLyricTitles ? state.displayTitle : nil) ?? state.title,
            artist: (correctLyricTitles ? state.displayArtist : nil) ?? state.artist,
            album: (correctLyricTitles ? state.displayAlbum : nil) ?? state.album
        )
    }
}
