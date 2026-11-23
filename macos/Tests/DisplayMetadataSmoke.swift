import Foundation

@main struct DisplayMetadataSmoke {
    static func main() {
        var checks = 0
        func unchanged(_ title: String, _ artist: String = "Example Artist", album: String = "Example Album", lyrics: String) {
            let value = DisplayMetadataResolver.resolve(title: title, artist: artist, album: album, lyricsText: lyrics)
            precondition(value == DisplayMetadata(title: title, artist: artist, album: album))
            checks += 1
        }
        func recovered(_ title: String, artist: String, album: String = "Example Album", lyrics: String,
                       expectedTitle: String = "A Synthetic Question (Explicit)",
                       expectedArtist: String = "Example Artist", expectedAlbum: String = "Example Album") {
            let value = DisplayMetadataResolver.resolve(title: title, artist: artist, album: album, lyricsText: lyrics)
            precondition(value.title == expectedTitle && value.artist == expectedArtist && value.album == expectedAlbum)
            precondition(value.wasCorrected)
            checks += 1
        }
        let headers = "[ti:A Synthetic Question (Explicit)]\n[ar:Example Artist]\n[al:Example Album]\n"
        let row = "[00:01.00]Someone may touch her, just once.\n"
        let composite = "A Synthetic Question (Explicit)-Example Artist"
        recovered("touch her", artist: composite, lyrics: headers + row)
        recovered("TOUCH   HER", artist: composite, lyrics: headers + row)
        recovered("touch her", artist: "A Synthetic Question (Explicit) - Example Artist - Example Album", lyrics: headers + row)
        recovered("touch her", artist: "A Synthetic Question (Explicit)—Example Artist", lyrics: headers + row)
        recovered("touch her", artist: "Example Artist", lyrics: headers + row)
        recovered("touch her", artist: "", lyrics: headers + row)
        recovered("touch her", artist: composite, album: "", lyrics: headers + row)
        recovered("", artist: composite, lyrics: headers)
        recovered("touch her", artist: composite, album: "A Different Album", lyrics: headers + row,
                  expectedAlbum: "A Different Album")

        // Real titles and hyphenated artist names remain literal.
        unchanged("A Synthetic Question (Explicit)", lyrics: headers + "[00:01]A Synthetic Question (Explicit)")
        unchanged("a synthetic question (explicit)", lyrics: headers + row)
        unchanged("An Actual New Song", "Artist-With-Hyphens", lyrics: headers + row)
        unchanged("touch her", "Artist-With-Hyphens", lyrics: "[00:01]Someone may touch her")
        unchanged("touch her", "A Synthetic Question (Explicit)-Example Artist", lyrics: "")
        recovered("touch her", artist: "Artist-With-Hyphens", lyrics: headers + row,
                  expectedArtist: "Artist-With-Hyphens")
        recovered("touch her", artist: "Song-With-Hyphens - Band-With-Hyphens",
                  lyrics: "[ti:Song-With-Hyphens]\n[ar:Band-With-Hyphens]\n" + row,
                  expectedTitle: "Song-With-Hyphens", expectedArtist: "Band-With-Hyphens")
        recovered("touch her", artist: "Song-With-Hyphens - Band-With-Hyphens",
                  lyrics: "[ar:Band-With-Hyphens]\n" + row,
                  expectedTitle: "Song-With-Hyphens", expectedArtist: "Band-With-Hyphens")
        recovered("touch her", artist: "Song-With-Hyphens - Band-With-Hyphens",
                  lyrics: "[ti:Song-With-Hyphens]\n" + row,
                  expectedTitle: "Song-With-Hyphens", expectedArtist: "Band-With-Hyphens")
        unchanged("touch her", "Unknown-Composite-Artist", lyrics: row)
        unchanged("touch her", "Song-Example Artist-Example Artist", album: "Example Artist",
                  lyrics: "[ar:Example Artist]\n" + row)

        // The whole phrase must occur within one timed row, at word boundaries.
        unchanged("touch her", composite, lyrics: headers + "[00:01]Do not untouch her\n")
        unchanged("touch her", composite, lyrics: headers + "[00:01]She can touch herself\n")
        unchanged("touch her", composite, lyrics: headers + "[00:01]She can touch her-kind\n")
        unchanged("touch her", composite, lyrics: headers + "[00:01]Do not pre-touch her\n")
        unchanged("touch her", composite, lyrics: headers + "[00:01]She can touch her's\n")
        unchanged("touch her", composite, lyrics: headers + "[00:01]Please touch\n[00:02]her hand\n")
        unchanged("touch her", composite, lyrics: headers + "Someone may touch her\n")
        unchanged("touch", composite, lyrics: headers + "[00:01]touch\n")
        unchanged("I", composite, lyrics: headers + "[00:01]I\n")
        unchanged("x-ray", composite, lyrics: headers + "[00:01]x-ray\n")
        recovered("don't leave", artist: composite, lyrics: headers + "[00:01]Please don’t leave today\n")
        recovered("touch her", artist: composite, lyrics: headers + "[00:01]<00:01.00>touch <00:01.50>her hand\n")
        recovered("touch her", artist: composite, lyrics: headers + "[00:01]Original row\n[00:01]Please touch her hand\n")
        recovered("穿过安静", artist: composite, lyrics: headers + "[00:01]我们穿过安静街道\n")
        unchanged("过安静", composite, lyrics: headers + "[00:01]我们穿过安静街道\n")
        unchanged("静", composite, lyrics: headers + "[00:01]静\n")

        // Header evidence is bounded and contradictory declarations fail closed.
        unchanged("touch her", composite, lyrics: headers + "[ti:A Conflicting Title]\n" + row)
        unchanged("touch her", composite, lyrics: headers + "[ar:A Conflicting Artist]\n" + row)
        recovered("touch her", artist: composite, lyrics: headers + "[TI:A Synthetic Question (Explicit)]\n" + row)
        recovered("touch her", artist: composite, lyrics: "\u{FEFF}[ti:A Synthetic Question (Explicit)][ar:Example Artist]\r\n" + row)
        unchanged("touch her", composite, lyrics: "[00:01][ti:A Synthetic Question (Explicit)]touch her\n")
        unchanged("touch her", composite, lyrics: "[ti:" + String(repeating: "a", count: 513) + "]\n" + row)
        unchanged("touch her", composite, lyrics: "[ti:Invalid\u{0001}Title]\n" + row)
        unchanged("touch her", composite, lyrics: headers + row + String(repeating: "x", count: LyricsDocument.maxSourceBytes))
        // Correct titles may clean an independently verified composite without
        // changing the title or guessing a split inside either complete name.
        recovered("A Synthetic Question (Explicit)", artist: composite, lyrics: headers + row)
        // Preserve Mac's Unicode behavior for nonprojected metadata.
        recovered("ＣＡＦＥ\u{301}　ＨＯＭＥ", artist: composite,
                  lyrics: headers + "[00:01]Please Café home tonight\n")
        let rawCaption = "home"
        let projected = DisplayMetadataResolver.resolveProjected(title: rawCaption, artist: "Raw Artist", album: "Raw Album",
            lyricsText: "", displayTitle: "Night Walk", displayArtist: "Verified Artist", displayAlbum: nil)
        precondition(projected.title == "Night Walk" && projected.artist == "Verified Artist" && projected.album == "Raw Album")
        let disabled = DisplayMetadataResolver.resolveProjected(title: rawCaption, artist: "Raw Artist", album: "Raw Album",
            lyricsText: headers + row, displayTitle: "Night Walk", displayArtist: "Verified Artist", displayAlbum: "Record",
            correctLyricTitles: false)
        precondition(disabled == DisplayMetadata(title: rawCaption, artist: "Raw Artist", album: "Raw Album"))
        let unknown = DisplayMetadataResolver.resolveProjected(title: rawCaption, artist: "Raw Artist", album: "Raw Album",
            lyricsText: headers + row, displayTitle: "", displayArtist: nil, displayAlbum: nil)
        precondition(unknown.title.isEmpty && unknown.artist == "Raw Artist")
        let legacy = DisplayMetadataResolver.resolveProjected(title: "touch her", artist: composite, album: "Example Album",
            lyricsText: headers + row, displayTitle: nil, displayArtist: nil, displayAlbum: nil)
        precondition(legacy.title == "A Synthetic Question (Explicit)")
        checks += 4
        print("PASS: \(checks) display-only metadata cases; trusted headers, bounded caption fragments, hyphens, ambiguity, normal titles and malformed inputs")
    }
}
