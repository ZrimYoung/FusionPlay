// The fields used by the presentation projection, independent of the bridge library.
struct Snapshot {
    let title: String
    let artist: String
    let album: String
    var displayTitle: String?
    var displayArtist: String?
    var displayAlbum: String?
}

@main struct DisplayMetadataSmoke {
    static func main() {
        let raw = DisplayMetadata(title: "A lyric fragment", artist: "Example title - Artist", album: "Album")
        let legacy = Snapshot(title: raw.title, artist: raw.artist, album: raw.album)
        precondition(DisplayMetadata(legacy, correctLyricTitles: true) == raw)

        let corrected = Snapshot(
            title: raw.title, artist: raw.artist, album: raw.album,
            displayTitle: "Example title", displayArtist: "Artist", displayAlbum: "A corrected album"
        )
        precondition(DisplayMetadata(corrected, correctLyricTitles: false) == raw)
        precondition(DisplayMetadata(corrected, correctLyricTitles: true) ==
            DisplayMetadata(title: "Example title", artist: "Artist", album: "A corrected album"))

        var unknownTitle = legacy
        unknownTitle.displayTitle = ""
        precondition(DisplayMetadata(unknownTitle, correctLyricTitles: true) ==
            DisplayMetadata(title: "", artist: raw.artist, album: raw.album))
        precondition(DisplayMetadata(unknownTitle, correctLyricTitles: false) == raw)
        print("PASS: Playback labels follow the preference, fall back for absent values, and preserve explicitly unknown titles")
    }
}
