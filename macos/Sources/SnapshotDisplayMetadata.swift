/// Presentation values never replace the transport snapshot used by controls.
extension DisplayMetadata {
    init(_ state: Snapshot, correctLyricTitles: Bool) {
        self = DisplayMetadataResolver.resolveProjected(title: state.title, artist: state.artist, album: state.album,
            lyricsText: state.lyricsText, displayTitle: state.displayTitle, displayArtist: state.displayArtist,
            displayAlbum: state.displayAlbum, correctLyricTitles: correctLyricTitles)
    }
}

extension DisplayMetadataCache {
    func resolve(_ state: Snapshot) -> DisplayMetadata {
        resolve(title: state.title, artist: state.artist, album: state.album, lyricsText: state.lyricsText,
                displayTitle: state.displayTitle, displayArtist: state.displayArtist, displayAlbum: state.displayAlbum)
    }
}
