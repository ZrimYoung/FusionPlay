import Foundation

struct PlayerPresentationLayout {
    enum Mode: Equatable {
        case stacked
        case paged
        case artworkAndControls
        case artworkAndLyrics
    }

    private static let columnsMinimumWidth: CGFloat = 660

    let mode: Mode
    let gutter: CGFloat
    let gap: CGFloat
    let coverSide: CGFloat
    let leadingWidth: CGFloat
    let contentWidth: CGFloat
    let lyricsHeight: CGFloat
    let verticalInset: CGFloat

    static func horizontalInset(for width: CGFloat) -> CGFloat {
        min(64, max(18, width * 0.052), width / 4)
    }

    static func usesNarrowPaging(width: CGFloat, enabled: Bool) -> Bool {
        enabled && width > 0 && width < columnsMinimumWidth
    }

    init(size: CGSize, showsLyrics: Bool, accessibilitySize: Bool,
         showsProgress: Bool = true, showsPlaybackControls: Bool = true, pagingEnabled: Bool = false) {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let canUseColumns = width >= Self.columnsMinimumWidth && !accessibilitySize
        if Self.usesNarrowPaging(width: width, enabled: pagingEnabled) {
            mode = .paged
        } else if canUseColumns && showsLyrics && height >= 360 {
            mode = .artworkAndLyrics
        } else if canUseColumns && !showsLyrics && width >= height * 1.12 {
            mode = .artworkAndControls
        } else {
            mode = .stacked
        }

        gutter = Self.horizontalInset(for: width)
        let availableWidth = max(0, width - gutter * 2)
        let compactGap = min(64, max(28, availableWidth * 0.058))
        verticalInset = min(24, max(12, 12 + (height - 360) * 0.1))
        let availableHeight = max(0, height - verticalInset * 2)
        lyricsHeight = min(520, max(280, height * 0.64))
        let playbackHeight: CGFloat = 120 + (showsProgress ? 58 : 0) + (showsPlaybackControls ? 72 : 0)

        switch mode {
        case .stacked, .paged:
            gap = compactGap
            contentWidth = min(availableWidth, 470)
            leadingWidth = contentWidth
            coverSide = min(contentWidth, 420, max(148, availableHeight - playbackHeight))
        case .artworkAndControls:
            gap = compactGap
            contentWidth = min(availableWidth, 920)
            leadingWidth = min(440, (contentWidth - gap) / 2)
            coverSide = min(leadingWidth, availableHeight)
        case .artworkAndLyrics:
            // Keep the original layout through normal iPad window widths.
            // On wider displays the centered reading area stops at 1,440pt.
            let t = min(1, max(0, (availableWidth - 1_180) / 420))
            let expansion = t * t * (3 - 2 * t)
            contentWidth = min(availableWidth, 1_180 + 260 * expansion)
            gap = min(64 + 32 * expansion, max(28, contentWidth * 0.058))
            let albumFraction = 0.43 - 0.05 * expansion
            leadingWidth = min(400 + 160 * expansion, (contentWidth - gap) * albumFraction)
            coverSide = min(leadingWidth, max(144, availableHeight - playbackHeight + 25))
        }
    }
}
