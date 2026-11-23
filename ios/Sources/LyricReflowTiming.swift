import SwiftUI

enum LyricReflowTiming {
    // Use the same vertical easing for the scroll and its per-row delay.
    static let verticalMove = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.32, y: 0),
        endControlPoint: UnitPoint(x: 0.24, y: 1)
    )

    static let staggerRange = 0...1_000
    static let defaultStaggerMilliseconds = 140
    static let staggerStep = 10
    static let maximumStaggerSpan = TimeInterval(staggerRange.upperBound) / 1_000
    static let viewportSteps = 32

    static let moveStorageKey = "lyricLineMoveMilliseconds"
    static let defaultMoveMilliseconds = 420
    static let moveMillisecondsRange = 100...1_500
    static let moveStepMilliseconds = 10
    static let defaultMoveDuration = TimeInterval(defaultMoveMilliseconds) / 1_000

    static func clampMoveMilliseconds(_ value: Int) -> Int {
        min(moveMillisecondsRange.upperBound, max(moveMillisecondsRange.lowerBound, value))
    }

    static func moveDuration(milliseconds: Int) -> TimeInterval {
        TimeInterval(clampMoveMilliseconds(milliseconds)) / 1_000
    }

    static func clampedStaggerMilliseconds(_ value: Int) -> Int {
        min(staggerRange.upperBound, max(staggerRange.lowerBound, value))
    }

    static func staggerSpan(milliseconds: Int) -> TimeInterval {
        TimeInterval(clampedStaggerMilliseconds(milliseconds)) / 1_000
    }

    static func staggerDelay(span: TimeInterval, position: Double) -> TimeInterval {
        guard span.isFinite, position.isFinite else { return 0 }
        return min(1, max(0, position)) * min(maximumStaggerSpan, max(0, span))
    }
}

struct LyricResizeTiming {
    static let duration: TimeInterval = 0.40
    static let maximumDelay: TimeInterval = 0.035
    static let fadeOutEnd = 0.40
    private static let invisibleDuration: TimeInterval = 0.024
    static let revealStart = fadeOutEnd + invisibleDuration / duration
    static let slideDuration: TimeInterval = 0.19

    let start: Date

    var end: Date { start.addingTimeInterval(Self.duration) }
    var reveal: Date { start.addingTimeInterval(Self.duration * Self.revealStart) }

    func heightWindow(expanding: Bool) -> ClosedRange<Date> {
        let phases = expanding ? (0.05, Self.revealStart) : (Self.fadeOutEnd, 0.92)
        let first = start.addingTimeInterval(Self.duration * phases.0)
        let last = start.addingTimeInterval(Self.duration * phases.1)
        return first...last
    }

    static func staggerSpan(playbackSpan: TimeInterval) -> TimeInterval {
        min(maximumDelay, playbackSpan * 0.25)
    }

    static func ease(_ progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return t * t * (3 - 2 * t)
    }
}

/// Text layout and row geometry are reported separately during the same frame.
final class LyricResizeClock {
    private var lastMeasurement: Date?

    func timing(at now: Date, delay: TimeInterval) -> LyricResizeTiming {
        let epoch: Date
        if let lastMeasurement, abs(now.timeIntervalSince(lastMeasurement)) < 1.0 / 60 {
            epoch = lastMeasurement
        } else {
            lastMeasurement = now
            epoch = now
        }
        return LyricResizeTiming(start: epoch.addingTimeInterval(delay))
    }
}

struct LyricResizeContext {
    var isVisible = true
    var delay: TimeInterval = 0
    var clock: LyricResizeClock?

    func timing(at now: Date) -> LyricResizeTiming {
        clock?.timing(at: now, delay: delay) ?? LyricResizeTiming(start: now)
    }
}

/// Carry only the prior presentation at the viewport ranks. A rapid burst
/// of timed lines still has a fixed animation cost and a bounded offset.
struct LyricFollowWave {
    let start: Date
    let direction: CGFloat
    let span: TimeInterval
    let duration: TimeInterval
    private let carriedOffsets: [CGFloat]

    init(start: Date, direction: CGFloat, span: TimeInterval, duration: TimeInterval,
         previous: Self? = nil) {
        self.start = start
        self.direction = direction
        self.span = span
        self.duration = duration
        if let previous, previous.end > start {
            carriedOffsets = (0...LyricReflowTiming.viewportSteps).map { rank in
                previous.offset(at: start, position: Double(rank) / Double(LyricReflowTiming.viewportSteps))
            }
        } else {
            carriedOffsets = []
        }
    }

    var end: Date { start.addingTimeInterval(duration + span) }

    func offset(at time: Date, position: Double) -> CGFloat {
        let delay = LyricReflowTiming.staggerDelay(span: span, position: position)
        let elapsed = time.timeIntervalSince(start)
        func eased(_ time: TimeInterval) -> Double {
            LyricReflowTiming.verticalMove.value(at: min(1, max(0, time / duration)))
        }
        let base = direction * 36 * CGFloat(eased(elapsed) - eased(elapsed - delay))
        let residual = carriedOffset(at: position) * CGFloat(1 - eased(elapsed))
        // Keep the starting offset continuous without growing the displacement
        // every time a new line interrupts an unfinished wave.
        let sameDirection = max(0, base >= 0 ? residual : -residual)
        return residual + base * max(0, 1 - sameDirection / 36)
    }

    private func carriedOffset(at position: Double) -> CGFloat {
        guard !carriedOffsets.isEmpty, position.isFinite else { return 0 }
        let rank = Int((min(1, max(0, position)) * Double(LyricReflowTiming.viewportSteps)).rounded())
        return carriedOffsets[rank]
    }
}
