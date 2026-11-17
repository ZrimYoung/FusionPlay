@main struct LyricsFollowPositionSmoke {
    static func main() {
        var follow = LyricsFollowPosition()
        precondition(follow.current(nil, connected: true) == nil)
        follow.observe(95_000, connected: true)
        precondition(follow.current(nil, connected: true) == 95_000,
                     "Missing progress must not scroll back to the first lyric")
        follow.observe(nil, connected: true)
        precondition(follow.current(nil, connected: true) == 95_000)
        precondition(follow.current(103_000, connected: true) == 103_000,
                     "A current progress value takes precedence before its observer runs")
        follow.observe(0, connected: true)
        precondition(follow.current(nil, connected: true) == 0,
                     "A real seek to zero must not be mistaken for missing progress")
        follow.observe(42_000, connected: true)
        follow.observe(nil, connected: false)
        precondition(follow.current(nil, connected: false) == nil)
        precondition(follow.current(nil, connected: true) == nil,
                     "Reconnection must not inherit a disconnected track position")
        follow.observe(77_000, connected: true)
        follow = LyricsFollowPosition()
        precondition(follow.current(nil, connected: true) == nil,
                     "A new track view identity starts without the old track position")
        print("PASS: lyrics follow retains omitted progress, accepts real zero, and resets across sessions/tracks")
    }
}
