import Foundation

enum CompactPlayerPage: String, CaseIterable {
    case playback, lyrics
}

/// A per-track exception never writes the saved automatic/always/never choice.
struct PlayerLyricsVisibilityState: Equatable {
    private(set) var temporaryVisibility: Bool?
    private var trackID: String?
    private var connected = false

    func isVisible(mode: LyricsDisplayMode, hasLyrics: Bool) -> Bool {
        temporaryVisibility ?? mode.isVisible(hasLyrics: hasLyrics)
    }
    mutating func request(_ visible: Bool, mode: LyricsDisplayMode, hasLyrics: Bool) {
        temporaryVisibility = visible == mode.isVisible(hasLyrics: hasLyrics) ? nil : visible
    }
    mutating func toggle(mode: LyricsDisplayMode, hasLyrics: Bool) {
        request(!isVisible(mode: mode, hasLyrics: hasLyrics), mode: mode, hasLyrics: hasLyrics)
    }
    mutating func observe(trackID: String, connected: Bool) {
        if !connected || (self.connected && self.trackID != trackID) { reset() }
        self.trackID = trackID; self.connected = connected
    }
    mutating func reset() { temporaryVisibility = nil }
}

enum NarrowPlayerPresentation {
    static let breakpoint: CGFloat = 600
    static func isPaged(width: CGFloat, enabled: Bool) -> Bool { enabled && width > 0 && width < breakpoint }
    static func isPaged(width: CGFloat, layout: NarrowPlayerLayout) -> Bool { isPaged(width: width, enabled: layout.isPaged) }
    static func minimumHeight(width: CGFloat, showsLyrics: Bool, pagingEnabled: Bool) -> CGFloat {
        isPaged(width: width, enabled: pagingEnabled) ? 260 : (showsLyrics && width < breakpoint ? width + 136 : 260)
    }
}

/// Precise wheel deltas are points, unlike a touch drag's screen-distance test.
/// Vertical intent and momentum never turn a page, and one gesture turns once.
struct NarrowPlayerSwipeState {
    private var horizontal: CGFloat = 0
    private var vertical: CGFloat = 0
    private var turned = false
    private enum Axis { case undecided, horizontal, vertical }
    private var axis = Axis.undecided
    var hasHorizontalIntent: Bool { axis == .horizontal }
    mutating func reset() { horizontal = 0; vertical = 0; turned = false; axis = .undecided }
    mutating func consume(x: CGFloat, y: CGFloat, momentum: Bool = false) -> CompactPlayerPage? {
        guard !momentum, !turned else { return nil }
        horizontal += x; vertical += abs(y)
        if axis == .undecided {
            if vertical >= 8 && vertical > abs(horizontal) * 1.2 { axis = .vertical }
            else if abs(horizontal) >= 8 && abs(horizontal) > vertical * 1.35 { axis = .horizontal }
        }
        guard axis == .horizontal, abs(horizontal) >= 32 else { return nil }
        turned = true
        return horizontal < 0 ? .lyrics : .playback
    }
}

/// Reserve controls first in very short paged playback windows.
struct PlayerMetadataLineBudget: Equatable {
    let titleLines: Int
    let subtitleLines: Int
    init(availableHeight: CGFloat, titleLineHeight: CGFloat, subtitleLineHeight: CGFloat,
         spacing: CGFloat, hasSubtitle: Bool) {
        var title = 3, subtitle = hasSubtitle ? 2 : 0
        while CGFloat(title) * titleLineHeight + CGFloat(subtitle) * subtitleLineHeight
                + (hasSubtitle ? spacing : 0) > availableHeight {
            if subtitle > 1 { subtitle -= 1 }
            else if title > 1 { title -= 1 }
            else { break }
        }
        titleLines = title; subtitleLines = max(1, subtitle)
    }
}

/// The paged playback column owns a square cover and uses scrolling only when
/// its minimum cover plus the selected controls cannot fit a short window.
struct PagedPlaybackLayout: Equatable {
    let horizontalInset: CGFloat
    let contentWidth: CGFloat
    let artworkSide: CGFloat
    let contentHeight: CGFloat
    let topInset: CGFloat = 44
    let bottomInset: CGFloat = 20
    init(size: CGSize, metadataHeight: CGFloat, showsProgress: Bool, showsTransport: Bool) {
        horizontalInset = size.width < 320 ? 18 : 24
        contentWidth = max(0, size.width - horizontalInset * 2)
        let details = metadataHeight + 8 + 18 + (showsProgress ? 48 : 0)
            + (showsTransport ? 52 : 0) + 48
        let availableArtworkHeight = size.height - topInset - bottomInset - details
        artworkSide = min(contentWidth, max(120, availableArtworkHeight))
        contentHeight = topInset + artworkSide + details + bottomInset
    }
}
