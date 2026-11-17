import Foundation
@main struct TimelineSmoke {
    static func main() {
        var source = PlaybackObservation(trackID: "a", title: "Song A", duration: 120_000,
                                         position: 10_000, connected: true, playing: true)
        var timeline = PlaybackTimeline()
        timeline.observe(source, now: 0)
        let first = timeline.begin(target: 50_000, now: 1)!
        precondition(timeline.displayPosition(now: 1.1) == 50_000)
        source.position = 10_800; timeline.observe(source, now: 1.8)
        precondition(timeline.isPending, "Ordinary progress falsely confirmed a distant seek")
        precondition(!timeline.expire(first, now: 5.9))
        precondition(timeline.expire(first, now: 6))
        precondition(timeline.displayPosition(now: 6) == 10_800)
        let second = timeline.begin(target: 60_000, now: 7)!
        precondition(!timeline.complete(first, dispatched: false), "Old completion overwrote new preview")
        source.position = 60_020; timeline.observe(source, now: 7.2)
        precondition(!timeline.isPending && timeline.displayPosition(now: 7.2) == 60_020)
        precondition(!timeline.expire(second, now: 20))
        source.position = 10_000; timeline.observe(source, now: 21)
        _ = timeline.begin(target: 11_000, now: 21)
        source.position = 10_500; timeline.observe(source, now: 21.5)
        precondition(timeline.isPending, "Nearby normal tick was mistaken for seek feedback")
        source.position = 11_020; timeline.observe(source, now: 21.6)
        precondition(!timeline.isPending)
        _ = timeline.begin(target: 5_000, now: 22)
        source.position = 5_020; timeline.observe(source, now: 22.1)
        precondition(!timeline.isPending)
        let failed = timeline.begin(target: 50_000, now: 23)!
        precondition(timeline.complete(failed, dispatched: false))
        precondition(!timeline.isPending && timeline.displayPosition(now: 23.1) == 5_020)
        _ = timeline.begin(target: 20_000, now: 24)
        source.trackID = "b"; source.title = "Song B"; source.position = 20_000
        timeline.observe(source, now: 24.1)
        precondition(!timeline.isPending, "New track retained old preview")
        _ = timeline.begin(target: 30_000, now: 25)
        source.connected = false; timeline.observe(source, now: 25.1)
        precondition(!timeline.isPending && timeline.begin(target: 0, now: 26) == nil)
        source.connected = true; source.duration = nil; timeline.observe(source, now: 27)
        precondition(timeline.begin(target: 0, now: 27) == nil)
        source.duration = 120_000; source.position = nil; timeline.observe(source, now: 28)
        precondition(timeline.begin(target: 0, now: 28) == nil)
        source.position = 0; source.playing = false; timeline.observe(source, now: 29)
        precondition(timeline.begin(target: 120_001, now: 29) == nil)
        precondition(timeline.begin(target: 0, now: 29) != nil)
        timeline.cancel(); precondition(!timeline.isPending)
        _ = timeline.begin(target: 120_000, now: 30)
        source.position = 120_000; timeline.observe(source, now: 30.1)
        precondition(!timeline.isPending && !source.playing)
        var captions = PlaybackTimeline()
        source.trackID = "stable"; source.title = "First caption"; source.position = 10_000
        source.playing = true
        captions.observe(source, now: 0)
        _ = captions.begin(target: 50_000, now: 0.1)
        source.title = "Second caption"; source.position = 11_000
        captions.observe(source, now: 1)
        precondition(captions.isPending && captions.displayPosition(now: 1) == 50_000,
                     "A caption change with a stable ID reset the pending seek")
        source.trackID = "different"
        captions.observe(source, now: 1.1)
        precondition(!captions.isPending, "A real ID change retained the old seek")
        source.trackID = ""; source.title = "Fallback A"
        captions.observe(source, now: 2)
        _ = captions.begin(target: 30_000, now: 2.1)
        source.title = "Fallback B"
        captions.observe(source, now: 2.2)
        precondition(!captions.isPending, "Title-only track changes must still cancel the old seek")
        print("PASS: shared seek feedback, timeout, stale completion, same-track confirmation, natural ticks, backward seek, pause, disconnect and bounds")
    }
}
