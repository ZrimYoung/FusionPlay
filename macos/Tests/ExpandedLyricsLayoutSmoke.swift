import Foundation

@main struct ExpandedLyricsLayoutSmoke {
    static func main() {
        var count = 0
        for size in [CGSize(width: 600, height: 260), CGSize(width: 600, height: 300),
                     CGSize(width: 892, height: 650), CGSize(width: 1200, height: 500),
                     CGSize(width: 1710, height: 1112), CGSize(width: 2560, height: 1440),
                     CGSize(width: 3440, height: 1440)] {
            for progress in [false, true] {
                for transport in [false, true] {
                    let layout = ExpandedLyricsLayout(size: size, showsProgress: progress, showsTransport: transport)
                    let reserved: CGFloat = 72 + (progress ? 36 : 0) + (transport ? 44 : 0)
                    precondition(abs(layout.contentWidth + 2 * layout.horizontalInset - size.width) < 0.01)
                    precondition(abs(layout.albumColumnWidth + layout.columnGap + layout.lyricsWidth - layout.contentWidth) < 0.01)
                    precondition(layout.artworkSide <= layout.albumColumnWidth && layout.artworkSide >= 60)
                    precondition(layout.artworkSide + reserved + 2 * layout.verticalPadding <= size.height + 0.01)
                    precondition(layout.lyricsWidth > 200 && layout.columnGap >= 28)
                    precondition(layout.contentWidth <= ExpandedLyricsLayout.maximumContentWidth)
                    count += 1
                }
            }
        }
        func layout(_ width: CGFloat) -> ExpandedLyricsLayout {
            ExpandedLyricsLayout(size: CGSize(width: width, height: 1112), showsProgress: true, showsTransport: false)
        }
        let full = layout(1710), old = layout(892), ultra = layout(2560)
        precondition(full.horizontalInset >= 160 && full.artworkSide > 450)
        precondition(full.artworkSide > old.artworkSide && full.columnGap > old.columnGap)
        precondition(ultra.contentWidth == ExpandedLyricsLayout.maximumContentWidth && ultra.horizontalInset >= 500)
        for boundary in [600.1, 900.0, 1600.0, 1700.0, 1800.0] {
            let before = layout(boundary - 0.01), after = layout(boundary + 0.01)
            precondition(abs(before.horizontalInset - after.horizontalInset) < 0.1)
            precondition(abs(before.albumColumnWidth - after.albumColumnWidth) < 0.1)
            precondition(abs(before.lyricsWidth - after.lyricsWidth) < 0.1)
        }
        print("PASS: \(count) proportional layout cases, centered reading stage, height budgets and continuous resize boundaries")
    }
}
