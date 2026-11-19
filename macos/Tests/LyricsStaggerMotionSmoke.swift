import Foundation

@main struct LyricsStaggerMotionSmoke {
    static func main() {
        precondition(LyricsStaggerTiming.defaultEnabled)
        precondition(LyricsStaggerTiming.enabledStorageKey == "staggerLyricMotion")
        precondition(LyricsStaggerTiming.millisecondsStorageKey == "lyricStaggerMilliseconds")
        precondition(LyricsStaggerTiming.defaultMilliseconds == 140)
        precondition(LyricsStaggerTiming.millisecondsRange == 0...1000)
        precondition(LyricsStaggerTiming.stepMilliseconds == 10)
        precondition(LyricsStaggerTiming.clampMilliseconds(Int.min) == 0)
        precondition(LyricsStaggerTiming.clampMilliseconds(Int.max) == 1000)
        precondition(LyricsStaggerTiming.clampMilliseconds(145) == 145)
        precondition(LyricsStaggerTiming.span(milliseconds: -10) == 0)
        precondition(LyricsStaggerTiming.span(milliseconds: 999) == 0.999)
        precondition(LyricsStaggerTiming.clampSpan(.nan) == 0)
        precondition(LyricsStaggerTiming.clampSpan(.infinity) == 0)
        precondition(LyricsStaggerTiming.delay(span: 0.24, position: .nan) == 0)
        precondition(LyricsStaggerTiming.delay(span: 0.24, position: -1) == 0)
        precondition(LyricsStaggerTiming.delay(span: 0.24, position: 2) == 0.24)

        for milliseconds in [0, 140, 240, 500, 1000] {
            let span = LyricsStaggerTiming.span(milliseconds: milliseconds)
            var previous: TimeInterval = -1
            for rank in 0...LyricsStaggerTiming.geometrySteps {
                let position = LyricsStaggerTiming.position(rank: rank)
                let delay = LyricsStaggerTiming.delay(span: span, position: position)
                precondition(delay >= previous && delay <= span + 0.000001,
                             "Visible rows must be delayed in top-to-bottom order")
                previous = delay
            }
            precondition(LyricsStaggerTiming.delay(span: span, position: 0) == 0)
            precondition(LyricsStaggerTiming.delay(span: span, position: 1) == span)
        }
        precondition(LyricsStaggerTiming.quantizedRank(midY: 500, viewportHeight: 1000, span: 0.14) == 16)
        precondition(LyricsStaggerTiming.quantizedRank(midY: 250, viewportHeight: 1000, span: 0.24) == 8)
        precondition(LyricsStaggerTiming.quantizedRank(midY: 251, viewportHeight: 1000, span: 0.24) == 8)
        precondition(LyricsStaggerTiming.quantizedRank(midY: -100, viewportHeight: 1000, span: 0.24) == 0)
        precondition(LyricsStaggerTiming.quantizedRank(midY: 2000, viewportHeight: 1000, span: 0.24) == 32)
        precondition(LyricsStaggerTiming.quantizedRank(midY: .nan, viewportHeight: 1000, span: 0.24) == 0)
        precondition(LyricsStaggerTiming.quantizedRank(midY: 500, viewportHeight: .infinity, span: 0.24) == 0)
        precondition(LyricsStaggerTiming.quantizedRank(midY: 500, viewportHeight: 0, span: 0.24) == 0)
        precondition(LyricsStaggerTiming.quantizedRank(midY: 500, viewportHeight: 1000, span: 0) == 0)

        precondition(LyricsStaggerTiming.span(milliseconds: 9999) == 1)
        precondition(LyricsStaggerTiming.moveStorageKey == "lyricLineMoveMilliseconds")
        precondition(LyricsStaggerTiming.defaultMoveMilliseconds == 420)
        precondition(LyricsStaggerTiming.moveMillisecondsRange == 100...1500)
        precondition(LyricsStaggerTiming.moveStepMilliseconds == 10)
        precondition(LyricsStaggerTiming.clampMoveMilliseconds(Int.min) == 100)
        precondition(LyricsStaggerTiming.clampMoveMilliseconds(Int.max) == 1500)
        precondition(LyricsStaggerTiming.clampMoveMilliseconds(425) == 425)
        precondition(LyricsStaggerTiming.moveDuration(milliseconds: 0) == 0.1)
        precondition(LyricsStaggerTiming.moveDuration(milliseconds: 420) == 0.42)
        precondition(LyricsStaggerTiming.moveDuration(milliseconds: 9999) == 1.5)
        precondition(LyricsStaggerTiming.clampMoveDuration(.nan) == 0.42)
        precondition(LyricsStaggerTiming.clampMoveDuration(.infinity) == 0.42)
        // Independent cubic Bezier samples: vertical scrolling must use the
        // same non-symmetric timing as its wave and row-height interpolation.
        for (phase, expected) in [(0.25, 0.3004358674), (0.5, 0.7731489248), (0.75, 0.9562768914)] {
            precondition(abs(LyricsStaggerTiming.verticalMove.value(at: phase) - expected) < 0.00001)
        }
        precondition(LyricsStaggerTiming.verticalMove.value(at: 0) == 0)
        precondition(LyricsStaggerTiming.verticalMove.value(at: 1) == 1)

        var row = LyricsRowFollowRank()
        precondition(row.position(following: false) == 0)
        row.observe(24, following: false)
        row.setFollowing(true)
        for rank in [20, 16, 12, 8] {
            row.observe(rank, following: true)
            row.setFollowing(true) // Replacing an overlapping wave preserves its rank.
            precondition(row.held == 24 && row.measured == rank)
            precondition(row.position(following: true) == 0.75,
                         "Scrolling geometry changed the active wave's delay")
        }
        row.setFollowing(false)
        precondition(row.held == nil && row.position(following: false) == 0.25)
        row.setFollowing(true)
        precondition(row.held == 8, "A new follow sequence did not capture the latest viewport rank")
        row.observe(30, following: false) // Cancellation/disabled motion releases the held rank.
        precondition(row.held == nil && row.position(following: false) == 30.0 / 32)
        var lazyRow = LyricsRowFollowRank()
        lazyRow.setFollowing(true)
        precondition(lazyRow.held == nil)
        lazyRow.observe(12, following: true)
        lazyRow.observe(25, following: true)
        precondition(lazyRow.held == 12 && lazyRow.position(following: true) == 12.0 / 32,
                     "A lazy row did not retain its first measured rank")

        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var checks = 0
        for moveMilliseconds in [100, 420, 1500] {
            let duration = LyricsStaggerTiming.moveDuration(milliseconds: moveMilliseconds)
            for milliseconds in [0, 140, 240, 500, 1000] {
                let span = LyricsStaggerTiming.span(milliseconds: milliseconds)
                let forward = LyricsFollowWave(start: start, direction: 1, span: span, duration: duration)
                let reverse = LyricsFollowWave(start: start, direction: -1, span: span, duration: duration)
                precondition(forward.duration == duration && forward.carrySampleCount == 0)
                precondition(abs(forward.end.timeIntervalSince(start) - (duration + span)) < 0.000001)
                for rank in 0...32 {
                    let position = LyricsStaggerTiming.position(rank: rank)
                    for elapsed in [-0.1, 0, 0.07, 0.14, 0.21, 0.32, 0.42, 0.56, 0.66, 1,
                                    duration, duration + span, duration + span + 0.1] {
                        let time = start.addingTimeInterval(elapsed)
                        let a = forward.offset(at: time, position: position)
                        let b = reverse.offset(at: time, position: position)
                        precondition(a.isFinite && b.isFinite && a >= -0.000001 && a <= 36.000001)
                        precondition(abs(a + b) < 0.000001, "Backward following must mirror forward following")
                        if span == 0 || rank == 0 || elapsed <= 0 || elapsed >= duration + span {
                            precondition(abs(a) < 0.000001, "The offset must start and finish at zero")
                        }
                        checks += 1
                    }
                }
            }
        }
        // Every actual row uses one of the 33 ranks. Repeated, alternating
        // follow requests must preserve its current offset without old chains.
        var interrupted = LyricsFollowWave(start: start, direction: 1, span: 1, duration: 1.5)
        var continuityChecks = 0
        for index in 1...800 {
            let time = start.addingTimeInterval(Double(index) * 0.017)
            let before = (0...32).map { rank in
                interrupted.offset(at: time, position: LyricsStaggerTiming.position(rank: rank))
            }
            let duration: TimeInterval = index.isMultiple(of: 3) ? 0.1 : 1.5
            let next = LyricsFollowWave(start: time, direction: index.isMultiple(of: 5) ? -1 : 1,
                span: index.isMultiple(of: 7) ? 0.5 : 1, duration: duration, previous: interrupted)
            precondition(next.carrySampleCount == 33)
            for rank in 0...32 {
                let position = LyricsStaggerTiming.position(rank: rank)
                precondition(abs(next.offset(at: time, position: position) - before[rank]) < 0.000001,
                             "Interrupting a wave reset a visible row offset")
                for delta in [0.001, 0.05, 0.2, 0.8, 1.6, 2.6] {
                    let value = next.offset(at: time.addingTimeInterval(delta), position: position)
                    precondition(value.isFinite && abs(value) <= 36.000001,
                                 "Continuous interruptions accumulated unbounded row offsets")
                }
                precondition(abs(next.offset(at: next.end, position: position)) < 0.000001)
                continuityChecks += 1
            }
            interrupted = next
        }
        let old = LyricsFollowWave(start: start, direction: 1, span: 1, duration: 1.5)
        let cancellation = start.addingTimeInterval(0.8)
        let tail = LyricsFollowWave(start: cancellation, direction: 0, span: 0, duration: 0.18, previous: old)
        precondition(tail.carrySampleCount == 33)
        for rank in 0...32 {
            let position = LyricsStaggerTiming.position(rank: rank)
            let oldValue = old.offset(at: cancellation, position: position)
            precondition(abs(tail.offset(at: cancellation, position: position) - oldValue) < 0.000001)
            var previous = abs(oldValue)
            for delta in [0.03, 0.09, 0.15, 0.18, 0.3] {
                let value = abs(tail.offset(at: cancellation.addingTimeInterval(delta), position: position))
                precondition(value <= previous + 0.000001, "Cancellation tail did not decay smoothly")
                previous = value
            }
            precondition(abs(tail.offset(at: tail.end, position: position)) < 0.000001)
        }
        let finished = LyricsFollowWave(start: old.end.addingTimeInterval(0.1), direction: 1,
                                        span: 1, duration: 1.5, previous: old)
        precondition(finished.carrySampleCount == 0)
        let example = LyricsFollowWave(start: start, direction: 1, span: 0.14)
        let expectedCurveOffset = 36 * (LyricsStaggerTiming.verticalMove.value(at: 0.5)
            - LyricsStaggerTiming.verticalMove.value(at: 1.0 / 6))
        precondition(abs(example.offset(at: start.addingTimeInterval(0.21), position: 1) - expectedCurveOffset) < 0.00001)
        let invalid = LyricsFollowWave(start: start, direction: 1, span: .infinity)
        precondition(invalid.end.timeIntervalSince(start).isFinite)
        precondition(invalid.offset(at: start.addingTimeInterval(0.2), position: 1) == 0)
        print("PASS: \(checks) wave samples at 0/140/240/500/1000ms and 100/420/1500ms movement, \(continuityChecks) bounded interruption checks, unified vertical timing, held viewport ranks and smooth cancellation tails")
    }
}
