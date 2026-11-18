import Foundation

@main struct PlayerPresentationSmoke {
    static func main() {
        for mode in LyricsDisplayMode.allCases {
            for available in [false, true] {
                var state = PlayerLyricsVisibilityState()
                state.observe(trackID: "stable-one", connected: true)
                let normal = mode.isVisible(hasLyrics: available)
                precondition(state.isVisible(mode: mode, hasLyrics: available) == normal)
                state.toggle(mode: mode, hasLyrics: available)
                precondition(state.isVisible(mode: mode, hasLyrics: available) == !normal)
                state.observe(trackID: "stable-one", connected: true)
                precondition(state.isVisible(mode: mode, hasLyrics: available) == !normal,
                             "Same stable track must preserve its exception through metadata updates")
                state.toggle(mode: mode, hasLyrics: available)
                precondition(state.temporaryVisibility == nil)
                state.toggle(mode: mode, hasLyrics: available)
                state.observe(trackID: "stable-two", connected: true)
                precondition(state.temporaryVisibility == nil)
                state.toggle(mode: mode, hasLyrics: available)
                state.observe(trackID: "stable-two", connected: false)
                precondition(state.temporaryVisibility == nil)
            }
        }
        for width in [260.0, 420, 599, 600, 892] {
            precondition(NarrowPlayerPresentation.isPaged(width: width, enabled: true) == (width < 600))
            precondition(!NarrowPlayerPresentation.isPaged(width: width, enabled: false))
            precondition(NarrowPlayerPresentation.minimumHeight(width: width, showsLyrics: true, pagingEnabled: true)
                         == 260, "Paging must not inherit the stacked lyric minimum")
            precondition(NarrowPlayerPresentation.minimumHeight(width: width, showsLyrics: true, pagingEnabled: false)
                         == (width < 600 ? width + 136 : 260))
        }
        var gesture = NarrowPlayerSwipeState()
        precondition(gesture.consume(x: -12, y: 2) == nil)
        precondition(gesture.consume(x: -24, y: 1) == .lyrics)
        precondition(gesture.consume(x: -80, y: 0) == nil, "One gesture turns once")
        gesture.reset()
        precondition(gesture.consume(x: 40, y: 3) == .playback)
        gesture.reset()
        precondition(gesture.consume(x: -40, y: 60) == nil, "Vertical lyric browsing must not turn pages")
        gesture.reset()
        precondition(gesture.consume(x: 0, y: 40) == nil)
        precondition(gesture.consume(x: 60, y: 0) == nil, "Vertical intent must stay locked for the entire gesture")
        gesture.reset()
        precondition(gesture.consume(x: -100, y: 0, momentum: true) == nil)
        let compactBudget = PlayerMetadataLineBudget(availableHeight: 70, titleLineHeight: 23, subtitleLineHeight: 15,
                                                     spacing: 5, hasSubtitle: true)
        precondition(compactBudget.titleLines == 2 && compactBudget.subtitleLines == 1,
                     "Minimum-height paged playback must reserve its progress and transport controls")
        let tall = PagedPlaybackLayout(size: CGSize(width: 420, height: 700), metadataHeight: 80,
                                       showsProgress: true, showsTransport: true)
        precondition(tall.artworkSide == tall.contentWidth && tall.contentHeight <= 700)
        let shorter = PagedPlaybackLayout(size: CGSize(width: 420, height: 560), metadataHeight: 80,
                                          showsProgress: true, showsTransport: true)
        precondition(shorter.artworkSide < tall.artworkSide && shorter.contentHeight <= 560)
        let minimum = PagedPlaybackLayout(size: CGSize(width: 260, height: 260), metadataHeight: 80,
                                          showsProgress: true, showsTransport: true)
        precondition(minimum.artworkSide == 120 && minimum.contentHeight > 260,
                     "Very short playback pages must scroll rather than distort the square artwork")
        let lyrics = LyricsDocument("[00:00]Opening line\n[00:06]A new line to read\n[00:12]Another line")
        precondition(PlayerCurrentLyricSummary.text(document: lyrics, positionMs: 8_000) == "A new line to read")
        precondition(PlayerCurrentLyricSummary.text(document: lyrics, positionMs: 1_000) == "Opening line")
        precondition(PlayerCurrentLyricSummary.text(document: LyricsDocument(""), positionMs: 8_000) == nil)
        precondition(PlayerCurrentLyricSummary.text(document: LyricsDocument("Untimed words"), positionMs: nil) == "Untimed words")
        print("PASS: lyric modes and temporary exceptions, narrow geometry, horizontal axis lock, square playback budgets and source-only current lyric summaries")
    }
}
