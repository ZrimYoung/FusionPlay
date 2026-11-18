import Foundation

struct PlayerPresentationLayout {
    enum Mode: Equatable {
        case stacked
        case artworkAndControls
        case artworkAndLyrics
    }

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

    init(size: CGSize, showsLyrics: Bool, accessibilitySize: Bool,
         showsProgress: Bool = true, showsPlaybackControls: Bool = true) {
        let width = max(0, size.width)
        let height = max(0, size.height)
        let canUseColumns = width >= 660 && !accessibilitySize
        if canUseColumns && showsLyrics && height >= 360 {
            mode = .artworkAndLyrics
        } else if canUseColumns && !showsLyrics && width >= height * 1.12 {
            mode = .artworkAndControls
        } else {
            mode = .stacked
        }

        gutter = Self.horizontalInset(for: width)
        let availableWidth = max(0, width - gutter * 2)
        gap = min(64, max(28, availableWidth * 0.058))
        verticalInset = min(24, max(12, 12 + (height - 360) * 0.1))
        let availableHeight = max(0, height - verticalInset * 2)
        lyricsHeight = min(520, max(280, height * 0.64))
        let playbackHeight: CGFloat = 120 + (showsProgress ? 58 : 0) + (showsPlaybackControls ? 72 : 0)

        switch mode {
        case .stacked:
            contentWidth = min(availableWidth, 470)
            leadingWidth = contentWidth
            coverSide = min(contentWidth, 420, max(148, availableHeight - playbackHeight))
        case .artworkAndControls:
            contentWidth = min(availableWidth, 920)
            leadingWidth = min(440, (contentWidth - gap) / 2)
            coverSide = min(leadingWidth, availableHeight)
        case .artworkAndLyrics:
            contentWidth = min(availableWidth, 1_180)
            leadingWidth = min(400, (contentWidth - gap) * 0.43)
            coverSide = min(leadingWidth, max(144, availableHeight - playbackHeight + 25))
        }
    }
}
