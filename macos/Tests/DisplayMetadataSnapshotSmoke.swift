import Foundation

@main struct DisplayMetadataSnapshotSmoke {
    @MainActor static func main() {
        // Omit all three additive fields to exercise the generated defaults.
        var state = Snapshot(phase: .playing, title: "home", artist: "Raw Artist", album: "Raw Album",
            trackId: "stable-song", artworkUrl: "", lyricsText: "", durationMs: 120_000, positionMs: 11_000,
            controlsAvailable: true, volume: 50, message: "", address: "", output: "", queueMs: 0,
            outputLatencyMs: 0, scheduleErrorMs: 0, underruns: 0, droppedFrames: 0, resyncs: 0)
        precondition(state.displayTitle == nil && state.displayArtist == nil && state.displayAlbum == nil)
        state.displayTitle = "Night Walk"
        state.displayArtist = "Verified Artist"
        let transport = state
        let corrected = DisplayMetadata(state, correctLyricTitles: true)
        let uncorrected = DisplayMetadata(state, correctLyricTitles: false)
        precondition(corrected.title == "Night Walk" && corrected.artist == "Verified Artist" && corrected.album == "Raw Album")
        precondition(uncorrected == DisplayMetadata(title: "home", artist: "Raw Artist", album: "Raw Album"))
        precondition(state == transport && state.title == "home" && state.trackId == "stable-song")
        let cache = DisplayMetadataCache()
        precondition(cache.resolve(state) == corrected)
        state.displayTitle = ""
        precondition(cache.resolve(state).title.isEmpty)
        precondition(DisplayMetadata(state, correctLyricTitles: false).title == "home")
        state.displayTitle = nil; state.displayArtist = nil
        state.title = "touch her"
        state.lyricsText = "[ti:Night Walk]\n[00:10]Someone may touch her tonight"
        precondition(cache.resolve(state).title == "Night Walk")
        precondition(DisplayMetadata(state, correctLyricTitles: false).title == "touch her")
        print("PASS: actual generated Snapshot defaults, raw transport preservation, correction opt-out, projected empty/nil distinction and cache refresh")
    }
}
