import Foundation

/// Exercises the real preview model without creating a receiver, a media
/// session, a window or a preference domain. Call from a main-actor async check.
enum LyricsMetadataGapChecks {
    @MainActor static func run(initialState: Snapshot, root: URL) async throws {
        var initial = initialState
        initial.controlsAvailable = true
        initial.trackId = "metadata-gap-origin"
        initial.title = "Metadata gap origin"
        initial.lyricsText = "[00:00.00]Original words\n[00:02.00]Another line"
        func model(_ name: String) -> ReceiverModel {
            ReceiverModel.preview(initial, artwork: nil, root: root.appendingPathComponent(name))
        }
        let late = model("metadata-gap-late")
        let timeout = model("metadata-gap-timeout")
        let rapid = model("metadata-gap-rapid")
        let disconnected = model("metadata-gap-disconnect")
        var lateState = initial, timeoutState = initial, rapidState = initial, disconnectedState = initial
        lateState.trackId = "metadata-gap-late-next"; lateState.lyricsText = ""
        timeoutState.trackId = "metadata-gap-no-lyrics"; timeoutState.lyricsText = ""
        rapidState.trackId = "metadata-gap-rapid-first"; rapidState.lyricsText = ""
        disconnectedState.trackId = "metadata-gap-disconnect-next"; disconnectedState.lyricsText = ""
        let started = ProcessInfo.processInfo.systemUptime
        for (candidate, state) in [(late, lateState), (timeout, timeoutState), (rapid, rapidState), (disconnected, disconnectedState)] {
            candidate.previewLyricsUpdate(state)
            precondition(candidate.lyrics.lines.isEmpty && candidate.lyricsLoading && candidate.lyricsAvailable,
                         "A new empty first frame must clear old words while retaining the lyric pane")
        }

        // Deliver the next track's actual payload through the production model.
        lateState.lyricsText = "[00:00.00]Late words for the new song"
        late.previewLyricsUpdate(lateState)
        try await settle("late lyrics parsed") { !late.lyricsLoading }
        precondition(late.lyricsAvailable && late.lyrics.lines.first?.text == "Late words for the new song")

        disconnectedState.controlsAvailable = false
        disconnected.previewLyricsUpdate(disconnectedState)
        precondition(disconnected.lyrics.lines.isEmpty && !disconnected.lyricsLoading && !disconnected.lyricsAvailable,
                     "Disconnect must cancel the waiting state immediately")
        disconnectedState.controlsAvailable = true
        disconnectedState.trackId = "metadata-gap-reconnected"
        disconnectedState.lyricsText = "[00:00.00]Reconnected words"
        disconnected.previewLyricsUpdate(disconnectedState)
        try await settle("reconnected lyrics parsed") { !disconnected.lyricsLoading }

        // Start a second new-track grace period after the first is already
        // running. Its deadline must belong to the latest track, not the first.
        try await pause(until: started + 0.7)
        rapidState.trackId = "metadata-gap-rapid-second"
        rapid.previewLyricsUpdate(rapidState)
        precondition(rapid.lyrics.lines.isEmpty && rapid.lyricsLoading && rapid.lyricsAvailable)
        try await pause(until: started + 1.1)
        timeout.previewLyricsUpdate(timeoutState)
        precondition(timeout.lyricsLoading && timeout.lyricsAvailable,
                     "A repeated empty frame must preserve the pending metadata wait")
        try await settle("empty metadata grace period expires", timeout: 1.2) { !timeout.lyricsLoading }
        precondition(!timeout.lyricsAvailable && timeout.lyrics.lines.isEmpty,
                     "A genuinely empty track must hide after the bounded wait")
        precondition(ProcessInfo.processInfo.systemUptime - started < 2.7,
                     "Repeated empty metadata restarted the original grace-period deadline")
        try await pause(until: started + 2.15)
        precondition(rapid.lyricsLoading && rapid.lyricsAvailable && rapid.lyrics.lines.isEmpty,
                     "An old track's timeout cancelled the latest track's metadata wait")
        precondition(late.lyricsAvailable && !late.lyricsLoading && late.lyrics.lines.first?.text == "Late words for the new song",
                     "A cancelled waiting task overwrote the late payload")
        precondition(disconnected.lyricsAvailable && !disconnected.lyricsLoading
                     && disconnected.lyrics.lines.first?.text == "Reconnected words",
                     "A cancelled disconnected task affected the new media session")
        rapidState.lyricsText = "[00:00.00]Latest track words"
        rapid.previewLyricsUpdate(rapidState)
        try await settle("latest rapid track parsed") { !rapid.lyricsLoading }
        precondition(rapid.lyricsAvailable && rapid.lyrics.lines.first?.text == "Latest track words")
        print("PASS: real preview-model metadata gap, late lyrics, bounded timeout, repeated empty frames, rapid tracks and disconnect cancellation")
    }

    @MainActor private static func settle(_ label: String, timeout: TimeInterval = 1,
                                          until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Timed out: " + label)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func pause(until deadline: TimeInterval) async throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }
}
