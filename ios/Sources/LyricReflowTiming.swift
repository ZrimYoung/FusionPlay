import Foundation

enum LyricReflowTiming {
    static let hideEnd = 0.31
    static let rowStart = 0.34
    static let rowEnd = 0.64
    static let showStart = 0.68

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

    static func reflowDuration(moveDuration: TimeInterval) -> TimeInterval {
        0.48 * moveDuration / defaultMoveDuration
    }

    static func slideDuration(moveDuration: TimeInterval) -> TimeInterval {
        0.19 * moveDuration / defaultMoveDuration
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
            let phase = min(1, max(0, time / duration))
            return phase * phase * (3 - 2 * phase)
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
