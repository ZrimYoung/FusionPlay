import Foundation

/// Shared scale policy for lyric rendering and appearance controls. Stored
/// percentages are clamped only when read; opening settings never rewrites them.
enum LyricsTypography {
    static let storageKey = "lyricsFontScalePercent"
    static let defaultScalePercent = 100
    static let scaleRange = 75...200
    static let scaleStep = 5

    static func clampScalePercent(_ value: Int) -> Int {
        min(scaleRange.upperBound, max(scaleRange.lowerBound, value))
    }
    static func scale(percent: Int) -> CGFloat {
        CGFloat(clampScalePercent(percent)) / 100
    }
}
