import Foundation

/// Reading geometry only: never publishes native window constraints.
struct ExpandedLyricsLayout: Equatable {
    static let maximumContentWidth: CGFloat = 1440
    let contentWidth: CGFloat
    let horizontalInset: CGFloat
    let verticalPadding: CGFloat
    let albumColumnWidth: CGFloat
    let columnGap: CGFloat
    let lyricsWidth: CGFloat
    let artworkSide: CGFloat

    init(size: CGSize, showsProgress: Bool, showsTransport: Bool) {
        let width = max(600, size.width)
        let height = max(260, size.height)
        let growth = Self.smoothstep((width - 600) / 1000)
        let insetFraction = 0.06 + 0.04 * growth
        let compactReadingInset = min(80, 36 + max(0, width - 600) * 0.1)
        let proportionalInset = max(compactReadingInset, width * insetFraction)
        contentWidth = min(Self.maximumContentWidth, width - 2 * proportionalInset)
        horizontalInset = (width - contentWidth) / 2
        verticalPadding = min(72, max(20, height * 0.06))
        columnGap = min(96, max(28, contentWidth * 0.065))
        let columns = contentWidth - columnGap
        let albumFraction = 0.44 - 0.06 * Self.smoothstep((width - 900) / 800)
        albumColumnWidth = columns * albumFraction
        lyricsWidth = columns - albumColumnWidth
        let reserved: CGFloat = 72 + (showsProgress ? 36 : 0) + (showsTransport ? 44 : 0)
        artworkSide = max(60, min(albumColumnWidth, height - verticalPadding * 2 - reserved))
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}
