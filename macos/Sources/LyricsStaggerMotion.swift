import Foundation
import SwiftUI

/// One policy shared by the settings controls, row wave and glyph reflow.
enum LyricsStaggerTiming {
    static let enabledStorageKey = "staggerLyricMotion"
    static let millisecondsStorageKey = "lyricStaggerMilliseconds"
    static let defaultEnabled = true
    static let defaultMilliseconds = 140
    static let millisecondsRange = 0...1000
    static let stepMilliseconds = 10
    static let maximumSpan: TimeInterval = 1
    static let geometrySteps = 32
    static let moveStorageKey = "lyricLineMoveMilliseconds"
    static let defaultMoveMilliseconds = 420
    static let moveMillisecondsRange = 100...1500
    static let moveStepMilliseconds = 10

    static func clampMoveMilliseconds(_ value: Int) -> Int {
        min(moveMillisecondsRange.upperBound, max(moveMillisecondsRange.lowerBound, value))
    }
    static func moveDuration(milliseconds: Int) -> TimeInterval {
        TimeInterval(clampMoveMilliseconds(milliseconds)) / 1_000
    }
    static func clampMoveDuration(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return moveDuration(milliseconds: defaultMoveMilliseconds) }
        return min(TimeInterval(moveMillisecondsRange.upperBound) / 1_000,
                   max(TimeInterval(moveMillisecondsRange.lowerBound) / 1_000, value))
    }

    static func clampMilliseconds(_ value: Int) -> Int {
        min(millisecondsRange.upperBound, max(millisecondsRange.lowerBound, value))
    }
    static func span(milliseconds: Int) -> TimeInterval {
        TimeInterval(clampMilliseconds(milliseconds)) / 1_000
    }
    static func clampSpan(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return 0 }
        return min(maximumSpan, max(0, value))
    }
    static func delay(span: TimeInterval, position: Double) -> TimeInterval {
        guard position.isFinite else { return 0 }
        return min(1, max(0, position)) * clampSpan(span)
    }
    static func quantizedRank(midY: CGFloat, viewportHeight: CGFloat, span: TimeInterval) -> Int {
        guard clampSpan(span) > 0, midY.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return 0 }
        let position = min(1, max(0, midY / viewportHeight))
        return Int((position * CGFloat(geometrySteps)).rounded())
    }
    static func position(rank: Int) -> Double {
        Double(min(geometrySteps, max(0, rank))) / Double(geometrySteps)
    }
}

private struct LyricsRowMotionDelayKey: EnvironmentKey {
    static let defaultValue: TimeInterval = 0
}

extension EnvironmentValues {
    var lyricsRowMotionDelay: TimeInterval {
        get { self[LyricsRowMotionDelayKey.self] }
        set { self[LyricsRowMotionDelayKey.self] = newValue }
    }
}

/// Adds only the lag relative to the ScrollView's follow movement. A new
/// wave samples the preceding presentation at the 33 actual viewport ranks,
/// retaining a fixed array rather than a recursive chain of old animations.
struct LyricsFollowWave: Equatable {
    static let duration: TimeInterval = 0.42
    let start: Date
    let direction: CGFloat
    let span: TimeInterval
    let duration: TimeInterval
    private let carriedOffsets: [CGFloat]

    init(start: Date, direction: CGFloat, span: TimeInterval,
         duration: TimeInterval = Self.duration, previous: Self? = nil) {
        self.start = start
        self.direction = direction.isFinite ? min(1, max(-1, direction)) : 0
        self.span = LyricsStaggerTiming.clampSpan(span)
        self.duration = LyricsStaggerTiming.clampMoveDuration(duration)
        if let previous, previous.end > start {
            carriedOffsets = (0...LyricsStaggerTiming.geometrySteps).map { rank in
                previous.offset(at: start, position: LyricsStaggerTiming.position(rank: rank))
            }
        } else { carriedOffsets = [] }
    }

    var end: Date { start.addingTimeInterval(duration + span) }
    var carrySampleCount: Int { carriedOffsets.count }

    func offset(at time: Date, position: Double) -> CGFloat {
        let delay = LyricsStaggerTiming.delay(span: span, position: position)
        let elapsed = time.timeIntervalSince(start)
        func eased(_ elapsed: TimeInterval) -> Double {
            let progress = min(1, max(0, elapsed / duration))
            return progress * progress * (3 - 2 * progress)
        }
        let base = direction * 36 * CGFloat(eased(elapsed) - eased(elapsed - delay))
        let residual = carry(at: position) * CGFloat(1 - eased(elapsed))
        // Same-direction restarts use the remaining amplitude headroom. This
        // preserves the sampled offset at t=0 and bounds arbitrarily frequent
        // restarts to +/-36pt without clipping the previous presentation.
        let sharedDirection = max(0, base >= 0 ? residual : -residual)
        return residual + base * max(0, 1 - sharedDirection / 36)
    }

    private func carry(at position: Double) -> CGFloat {
        guard !carriedOffsets.isEmpty, position.isFinite else { return 0 }
        let index = min(1, max(0, position)) * Double(LyricsStaggerTiming.geometrySteps)
        let low = min(carriedOffsets.count - 1, max(0, Int(index.rounded(.down))))
        let high = min(carriedOffsets.count - 1, low + 1)
        let fraction = CGFloat(index - Double(low))
        return carriedOffsets[low] + (carriedOffsets[high] - carriedOffsets[low]) * fraction
    }
}

/// Quantized viewport position keeps scroll geometry from writing state on
/// every pixel. Both glyph reflow and the row-follow wave use the same delay.
struct LyricsRowStagger: ViewModifier {
    let span: TimeInterval
    let viewport: String
    let viewportHeight: CGFloat
    let wave: LyricsFollowWave?
    @State private var rank = 0

    func body(content: Content) -> some View {
        let position = LyricsStaggerTiming.position(rank: rank)
        let delay = LyricsStaggerTiming.delay(span: span, position: position)
        let activeWave = LyricsStaggerTiming.clampSpan(span) > 0 ? wave : nil
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: activeWave == nil)) { context in
            content
                .environment(\.lyricsRowMotionDelay, delay)
                .offset(y: activeWave?.offset(at: context.date, position: position) ?? 0)
        }
        .onGeometryChange(for: Int.self) { geometry in
            LyricsStaggerTiming.quantizedRank(midY: geometry.frame(in: .named(viewport)).midY,
                                               viewportHeight: viewportHeight, span: span)
        } action: { rank = $0 }
    }
}
