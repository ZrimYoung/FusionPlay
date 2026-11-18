import Foundation

/// Pure policy/clock checks. No MPRemoteCommandCenter or media session is created.
enum SystemMediaSeekChecks {
    static func run(state initial: Snapshot) {
        var state = initial
        state.controlsAvailable = true; state.phase = .playing
        state.trackId = "raw-track-A"; state.title = "Raw transport title"
        state.durationMs = 120_000; state.positionMs = 5_000
        let track = MediaSeekTrack(state)!
        let request = track.request(at: 17.25)!
        precondition(request.positionMs == 17_250)
        precondition(track.request(at: 300)?.positionMs == 120_000)
        precondition(track.request(at: .greatestFiniteMagnitude)?.positionMs == 120_000)
        for invalid: Double in [-1, -.infinity, .infinity, .nan] {
            precondition(track.request(at: invalid) == nil, "Non-finite/negative system targets must be rejected")
        }
        precondition(request.isCurrent(in: state, canSeek: true))
        precondition(!request.isCurrent(in: state, canSeek: false), "A queued callback must recheck the model busy/control gate")

        var changed = state
        changed.title = "A changing lyric line"
        precondition(request.isCurrent(in: changed, canSeek: true), "A stable raw ID survives display-title updates")
        changed.trackId = "raw-track-B"
        precondition(!request.isCurrent(in: changed, canSeek: true), "An old system drag must never seek the replacement track")
        changed = state; changed.durationMs = 121_000
        precondition(!request.isCurrent(in: changed, canSeek: true))
        changed = state; changed.controlsAvailable = false
        precondition(!request.isCurrent(in: changed, canSeek: true))
        changed = state; changed.positionMs = nil
        precondition(!request.isCurrent(in: changed, canSeek: true))
        changed = state; changed.durationMs = 0
        precondition(MediaSeekTrack(changed) == nil)

        var fallback = state
        fallback.trackId = ""; fallback.title = "Raw lyric-title fragment"
        let fallbackRequest = MediaSeekTrack(fallback)!.request(at: 20)!
        let labels = DisplayMetadata(title: "Corrected song name", artist: "Artist", album: "Album")
        fallback.displayTitle = labels.title; fallback.displayArtist = labels.artist; fallback.displayAlbum = labels.album
        let shown = MediaPresentation(fallback, metadata: DisplayMetadata(fallback, correctLyricTitles: true))!
        precondition(shown.title == labels.title && fallbackRequest.track.fallbackTitle == fallback.title)
        precondition(fallbackRequest.isCurrent(in: fallback, canSeek: true))
        fallback.title = labels.title
        precondition(!fallbackRequest.isCurrent(in: fallback, canSeek: true), "Display correction must not replace the raw fallback identity")
        fallback.title = ""; precondition(MediaSeekTrack(fallback) == nil, "An anonymous item cannot safely identify a queued system seek")
        fallback = state; fallback.durationMs = UInt64.max
        precondition(MediaSeekTrack(fallback)!.request(at: .greatestFiniteMagnitude)?.positionMs == UInt64.max)

        let gate = MediaCommandGate()
        gate.update(enabled: false, playing: true, seekTrack: track)
        precondition(gate.resolveSeek(20) == nil && gate.resolve(.pause) == nil)
        gate.update(enabled: true, playing: true)
        precondition(gate.resolveSeek(20) == nil && gate.resolve(.pause) == .pause,
                     "Unavailable seeking must not disable valid transport controls")
        gate.update(enabled: true, playing: true, seekTrack: track)
        precondition(gate.resolveSeek(.nan) == nil && gate.resolveSeek(20)?.track == track,
                     "Invalid events must not consume the next valid seek")
        precondition(gate.resolve(.next) == nil && gate.resolveSeek(30) == nil,
                     "Seek and transport callbacks must share one dispatch reservation")
        gate.update(enabled: false, playing: false, seekTrack: track)
        precondition(gate.resolveSeek(20) == nil)
        gate.update(enabled: true, playing: false, seekTrack: track)
        precondition(gate.resolve(nil) == .play && gate.resolveSeek(20) == nil)

        let reservations = MediaReservationProbe()
        gate.update(enabled: true, playing: true, seekTrack: track)
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            let accepted = index.isMultiple(of: 2) ? gate.resolveSeek(20) != nil : gate.resolve(.pause) != nil
            if accepted { reservations.record() }
        }
        precondition(reservations.count == 1, "Concurrent remote callbacks dispatched more than one command")

        var timeline = PlaybackTimeline()
        let source = PlaybackObservation(trackID: state.trackId, title: state.title,
            duration: state.durationMs, position: state.positionMs, connected: true, playing: true)
        timeline.observe(source, now: 100)
        let pending = timeline.begin(target: 40_000, now: 100)!
        timeline.complete(pending, dispatched: true)
        precondition(timeline.isPending && timeline.source?.position == 5_000,
                     "System acceptance is not a phone-side position confirmation")
        precondition(timeline.displayPosition(now: 101) == 40_000 && MediaPresentation(state)!.position == 5,
                     "Optimistic app feedback must not overwrite the source-only system clock")
        timeline.observe(source, now: 101)
        precondition(timeline.isPending, "An unchanged phone snapshot must not confirm seeking")
        var confirmed = source; confirmed.position = 40_500
        timeline.observe(confirmed, now: 101.2)
        precondition(!timeline.isPending)
        let failed = timeline.begin(target: 20_000, now: 102)!
        timeline.complete(failed, dispatched: false)
        precondition(!timeline.isPending)
        let oldTrackSeek = timeline.begin(target: 30_000, now: 103)!
        var replacement = source; replacement.trackID = "raw-track-B"
        timeline.observe(replacement, now: 103.1)
        precondition(!timeline.isPending && !timeline.complete(oldTrackSeek, dispatched: true))
        print("System seek policy: raw identity, stale-track rejection, bounds, busy/shared reservation, 128 concurrent callbacks and phone-confirmed timeline: PASS (no media publication)")
    }
}

private final class MediaReservationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
