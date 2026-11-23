import Foundation
import CoreGraphics

enum PlayerCanvasElement: String, CaseIterable, Hashable {
    case artwork, metadata, progress, previous, playPause, next
    case lyrics, lyricSummary, lyricsHeader, coverBackdrop
}

struct PlayerCanvasNode: Equatable {
    var frame: CGRect
    var opacity: Double

    init(frame: CGRect, opacity: Double = 1) {
        self.frame = frame
        self.opacity = opacity
    }
}

/// Frames use the canvas's top-left coordinate system. Playback nodes belong
/// to the persistent playback scroller; lyrics/header remain in root coordinates.
struct PlayerCanvasPose: Equatable {
    var nodes: [PlayerCanvasElement: PlayerCanvasNode]
    var titleSize: CGFloat = 20
    var subtitleSize: CGFloat = 12
    var metadataSpacing: CGFloat = 5
    var subtitleOpacity: Double = 0.75
    var artworkRadius: CGFloat = 12
    var glassOpacity: Double = 0
    var contentHeight: CGFloat = 1
    var controlsHeight: CGFloat = 0
    var titleLines = 1
    var subtitleLines = 1

    init(nodes: [PlayerCanvasElement: PlayerCanvasNode] = [:], titleSize: CGFloat = 20,
         subtitleSize: CGFloat = 12, metadataSpacing: CGFloat = 5, subtitleOpacity: Double = 0.75,
         artworkRadius: CGFloat = 12, glassOpacity: Double = 0, contentHeight: CGFloat = 1,
         controlsHeight: CGFloat = 0, titleLines: Int = 1, subtitleLines: Int = 1) {
        self.nodes = Dictionary(uniqueKeysWithValues: PlayerCanvasElement.allCases.map {
            ($0, nodes[$0] ?? PlayerCanvasNode(frame: CGRect(x: 0, y: 0, width: 1, height: 1), opacity: 0))
        })
        self.titleSize = titleSize; self.subtitleSize = subtitleSize; self.metadataSpacing = metadataSpacing
        self.subtitleOpacity = subtitleOpacity; self.artworkRadius = artworkRadius; self.glassOpacity = glassOpacity
        self.contentHeight = contentHeight; self.controlsHeight = controlsHeight
        self.titleLines = titleLines; self.subtitleLines = subtitleLines
    }
    subscript(_ element: PlayerCanvasElement) -> PlayerCanvasNode {
        get { nodes[element] ?? PlayerCanvasNode(frame: CGRect(x: 0, y: 0, width: 1, height: 1), opacity: 0) }
        set { nodes[element] = newValue }
    }

    static func interpolate(from: Self, to: Self, progress: Double) -> Self {
        let t = CGFloat(progress.isFinite ? min(1, max(0, progress)) : 0)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        func alpha(_ a: Double, _ b: Double) -> Double { a + (b - a) * Double(t) }
        var result = Self()
        for element in PlayerCanvasElement.allCases {
            let a = from[element], b = to[element]
            result[element] = PlayerCanvasNode(frame: CGRect(
                x: mix(a.frame.minX, b.frame.minX), y: mix(a.frame.minY, b.frame.minY),
                width: mix(a.frame.width, b.frame.width), height: mix(a.frame.height, b.frame.height)),
                opacity: alpha(a.opacity, b.opacity))
        }
        result.titleSize = mix(from.titleSize, to.titleSize)
        result.subtitleSize = mix(from.subtitleSize, to.subtitleSize)
        result.metadataSpacing = mix(from.metadataSpacing, to.metadataSpacing)
        result.subtitleOpacity = alpha(from.subtitleOpacity, to.subtitleOpacity)
        result.artworkRadius = mix(from.artworkRadius, to.artworkRadius)
        result.glassOpacity = alpha(from.glassOpacity, to.glassOpacity)
        result.contentHeight = mix(from.contentHeight, to.contentHeight)
        result.controlsHeight = mix(from.controlsHeight, to.controlsHeight)
        result.titleLines = to.titleLines
        result.subtitleLines = to.subtitleLines
        return result
    }
    func interpolated(to target: Self, progress: Double) -> Self {
        Self.interpolate(from: self, to: target, progress: progress)
    }
}

typealias PlayerCanvasMetadataMeasure = (_ width: CGFloat, _ titleSize: CGFloat,
    _ subtitleSize: CGFloat, _ spacing: CGFloat, _ titleLines: Int, _ subtitleLines: Int) -> CGFloat

/// Pure endpoint geometry. Animation timing and native window constraints are
/// deliberately owned by the caller, so a live resize cannot suppress motion.
struct PlayerResponsiveLayout {
    let pose: PlayerCanvasPose

    init(size: CGSize, layout: NarrowPlayerLayout, showLyrics: Bool, page: CompactPlayerPage,
         showControls: Bool, showsProgress: Bool, showsTransport: Bool,
         headerArtwork: Bool, headerInfo: Bool, wraps: Bool,
         coverTitleLines: Int, coverSubtitleLines: Int,
         measureMetadata: @escaping PlayerCanvasMetadataMeasure) {
        let width = max(1, size.width.isFinite ? size.width : 260)
        let height = max(1, size.height.isFinite ? size.height : 260)
        let size = CGSize(width: width, height: height)
        let titleLines = wraps ? 3 : 1, subtitleLines = wraps ? 2 : 1
        func measured(_ w: CGFloat, _ title: CGFloat, _ subtitle: CGFloat,
                      _ spacing: CGFloat, _ titles: Int, _ subtitles: Int) -> CGFloat {
            let result = measureMetadata(max(1, w), title, subtitle, spacing, titles, subtitles)
            return max(1, result.isFinite ? result : title + subtitle + spacing)
        }
        var result = PlayerCanvasPose()
        result.contentHeight = height
        result.titleLines = titleLines; result.subtitleLines = subtitleLines
        // A hidden viewport keeps real dimensions and its native scroll identity.
        result[.lyrics] = PlayerCanvasNode(frame: CGRect(x: width + 16, y: 44,
            width: max(1, width - 32), height: max(1, height - 56)), opacity: 0)
        result[.lyricsHeader] = PlayerCanvasNode(frame: CGRect(x: width + 20, y: 52,
            width: max(1, width - 40), height: 56), opacity: 0)

        func buttons(in row: CGRect, large: Bool, opacity: Double) -> [PlayerCanvasElement: PlayerCanvasNode] {
            let center = row.midX
            if large {
                return [
                    .previous: PlayerCanvasNode(frame: CGRect(x: center - 103, y: row.minY + 9, width: 44, height: 44), opacity: opacity),
                    .playPause: PlayerCanvasNode(frame: CGRect(x: center - 31, y: row.minY, width: 62, height: 62), opacity: opacity),
                    .next: PlayerCanvasNode(frame: CGRect(x: center + 59, y: row.minY + 9, width: 44, height: 44), opacity: opacity)
                ]
            }
            return [
                .previous: PlayerCanvasNode(frame: CGRect(x: center - 74, y: row.minY, width: 44, height: 44), opacity: opacity),
                .playPause: PlayerCanvasNode(frame: CGRect(x: center - 22, y: row.minY, width: 44, height: 44), opacity: opacity),
                .next: PlayerCanvasNode(frame: CGRect(x: center + 30, y: row.minY, width: 44, height: 44), opacity: opacity)
            ]
        }
        func assignButtons(_ row: CGRect, large: Bool, opacity: Double) {
            for (element, node) in buttons(in: row, large: large, opacity: opacity) { result[element] = node }
        }

        if width < NarrowPlayerPresentation.breakpoint, layout.isCover {
            let expanded = layout == .original && showLyrics
            let playback = expanded || page == .playback
            let offset: CGFloat = playback ? 0 : -width
            let visible = playback && showControls
            result.titleSize = width < 320 ? 17 : 20
            result.subtitleSize = 12; result.metadataSpacing = 5; result.subtitleOpacity = 0.75
            result.artworkRadius = 0
            result.titleLines = wraps ? max(1, min(3, coverTitleLines)) : 1
            result.subtitleLines = wraps ? max(1, min(2, coverSubtitleLines)) : 1
            let textWidth = max(1, width - 32)
            let metadataHeight = measured(textWidth, result.titleSize, 12, 5, result.titleLines, result.subtitleLines)
            let controlsHeight: CGFloat = 32 + metadataHeight + (showsProgress ? 44 : 0) + (showsTransport ? 46 : 0)
            result.controlsHeight = controlsHeight
            let metadataY = max(16, width - controlsHeight + 16)
            let progressY = metadataY + metadataHeight + (showsProgress ? 8 : 0)
            let transportY = metadataY + metadataHeight + (showsProgress ? 44 : 0) + (showsTransport ? 2 : 0)
            result[.artwork] = PlayerCanvasNode(frame: CGRect(x: offset, y: 0, width: width, height: width), opacity: playback ? 1 : 0)
            result[.coverBackdrop] = PlayerCanvasNode(frame: result[.artwork].frame, opacity: visible ? 1 : 0)
            result[.metadata] = PlayerCanvasNode(frame: CGRect(x: offset + 16, y: metadataY, width: textWidth, height: metadataHeight), opacity: visible ? 1 : 0)
            result[.progress] = PlayerCanvasNode(frame: CGRect(x: offset + 16, y: progressY, width: textWidth, height: 36), opacity: visible && showsProgress ? 1 : 0)
            assignButtons(CGRect(x: offset + 16, y: transportY, width: textWidth, height: 44), large: false, opacity: visible && showsTransport ? 1 : 0)
            let lyricInset: CGFloat = width < 320 ? 16 : 22
            if expanded {
                let pane = max(0, height - width), gap = min(8, pane)
                let lyricHeight = max(0, pane - gap - 12)
                result[.lyrics] = PlayerCanvasNode(frame: CGRect(x: lyricInset, y: width + gap,
                    width: max(1, width - lyricInset * 2), height: max(1, lyricHeight)), opacity: lyricHeight > 0 ? 1 : 0)
            } else {
                result[.lyrics] = PlayerCanvasNode(frame: CGRect(x: (playback ? width : 0) + lyricInset, y: 44,
                    width: max(1, width - lyricInset * 2), height: max(1, height - 56)), opacity: playback ? 0 : 1)
            }
            result.contentHeight = max(height, width)
        } else if width < NarrowPlayerPresentation.breakpoint {
            let maximum = PagedPlaybackLayout.maximumContentWidth(for: width)
            let paged = PagedPlaybackLayout(size: size,
                metadataHeight: measured(maximum, 22, 13, 5, titleLines, subtitleLines),
                showsProgress: showsProgress, showsTransport: showsTransport,
                metadataHeightForWidth: { measured($0, 22, 13, 5, titleLines, subtitleLines) })
            let column = max(1, paged.contentWidth)
            let textHeight = measured(column, 22, 13, 5, titleLines, subtitleLines)
            let stackHeight = column + 18 + textHeight + 12 + 34 + (showsProgress ? 48 : 0) + (showsTransport ? 52 : 0)
            let top = 44 + max(0, (height - 88 - stackHeight) / 2)
            let playback = page == .playback
            let offset: CGFloat = playback ? 0 : -width
            let x = paged.horizontalInset + offset
            result.titleSize = 22; result.subtitleSize = 13; result.metadataSpacing = 5; result.subtitleOpacity = 0.7
            result[.artwork] = PlayerCanvasNode(frame: CGRect(x: x, y: top, width: column, height: column), opacity: playback ? 1 : 0)
            let metadataY = top + column + 18
            result[.metadata] = PlayerCanvasNode(frame: CGRect(x: x, y: metadataY, width: column, height: textHeight), opacity: playback ? 1 : 0)
            let summaryY = metadataY + textHeight + 12
            result[.lyricSummary] = PlayerCanvasNode(frame: CGRect(x: x, y: summaryY, width: column, height: 34), opacity: playback ? 1 : 0)
            let progressY = summaryY + 34 + (showsProgress ? 12 : 0)
            result[.progress] = PlayerCanvasNode(frame: CGRect(x: x, y: progressY, width: column, height: 36), opacity: playback && showsProgress ? 1 : 0)
            let transportY = summaryY + 34 + (showsProgress ? 48 : 0) + (showsTransport ? 8 : 0)
            assignButtons(CGRect(x: x, y: transportY, width: column, height: 44), large: false, opacity: playback && showsTransport ? 1 : 0)
            let headerTextWidth = max(1, width - 40 - (headerArtwork ? 68 : 0))
            let headerTextHeight = headerInfo ? measured(headerTextWidth, 15, 11, 3, wraps ? 2 : 1, subtitleLines) : 0
            let headerHeight: CGFloat = max(1, headerArtwork ? 56 : 0, headerTextHeight)
            let showsHeader = headerArtwork || headerInfo
            let lyricPageX: CGFloat = playback ? width : 0
            result[.lyricsHeader] = PlayerCanvasNode(frame: CGRect(x: lyricPageX + 20, y: 52,
                width: max(1, width - 40), height: headerHeight), opacity: !playback && showsHeader ? 1 : 0)
            let lyricsTop: CGFloat = showsHeader ? 52 + headerHeight + 10 : 44
            let lyricInset: CGFloat = width < 320 ? 16 : 22
            result[.lyrics] = PlayerCanvasNode(frame: CGRect(x: lyricPageX + lyricInset, y: lyricsTop,
                width: max(1, width - lyricInset * 2), height: max(1, height - lyricsTop - 12)), opacity: playback ? 0 : 1)
            result.contentHeight = max(height, top + stackHeight + 44)
        } else if showLyrics {
            let wide = ExpandedLyricsLayout(size: size, showsProgress: showsProgress, showsTransport: showsTransport)
            let column = wide.albumColumnWidth
            let textHeight = measured(column, 20, 12, 5, titleLines, subtitleLines)
            let baseHeight = measured(column, 20, 12, 5, 1, 1)
            let side = max(60, min(column, wide.artworkSide - max(0, textHeight - baseHeight)))
            let stackHeight = side + 14 + textHeight + 10 + (showsProgress ? 36 : 0) + (showsTransport ? 44 : 0)
            let top = max(wide.verticalPadding, (height - stackHeight) / 2)
            let x = wide.horizontalInset
            result.titleSize = 20; result.subtitleSize = 12; result.metadataSpacing = 5; result.subtitleOpacity = 0.7
            result[.artwork] = PlayerCanvasNode(frame: CGRect(x: x, y: top, width: side, height: side))
            let metadataY = top + side + 14
            result[.metadata] = PlayerCanvasNode(frame: CGRect(x: x, y: metadataY, width: column, height: textHeight))
            let progressY = metadataY + textHeight + 10
            result[.progress] = PlayerCanvasNode(frame: CGRect(x: x, y: progressY, width: column, height: 36), opacity: showsProgress ? 1 : 0)
            assignButtons(CGRect(x: x, y: progressY + (showsProgress ? 36 : 0), width: column, height: 44), large: false, opacity: showsTransport ? 1 : 0)
            result[.lyrics] = PlayerCanvasNode(frame: CGRect(x: x + column + wide.columnGap, y: wide.verticalPadding,
                width: max(1, wide.lyricsWidth), height: max(1, height - wide.verticalPadding * 2)))
            result.contentHeight = max(height, top + stackHeight + wide.verticalPadding)
        } else {
            let inset = min(80, 36 + max(0, width - 600) * 0.1)
            let available = max(1, width - inset * 2)
            let side = max(60, min(360, height - 48, width * 0.37))
            let details = max(1, min(440, available - side - 28))
            let groupWidth = side + 28 + details
            let textHeight = measured(details, 28, 14, 9, titleLines, subtitleLines)
            let transportHeight: CGFloat = showsTransport ? 68 : 0
            let detailsHeight = max(side, max(86, textHeight) + 18 + (showsProgress ? 36 : 0) + transportHeight)
            let top = max(24, (height - detailsHeight) / 2)
            let x = (width - groupWidth) / 2
            let textX = x + side + 28
            result.titleSize = 28; result.subtitleSize = 14; result.metadataSpacing = 9; result.subtitleOpacity = 0.72
            result.glassOpacity = showsTransport ? 1 : 0
            result[.artwork] = PlayerCanvasNode(frame: CGRect(x: x, y: top, width: side, height: side))
            result[.metadata] = PlayerCanvasNode(frame: CGRect(x: textX, y: top, width: details, height: textHeight))
            let progressY = top + detailsHeight - transportHeight - 36
            result[.progress] = PlayerCanvasNode(frame: CGRect(x: textX, y: progressY, width: details, height: 36), opacity: showsProgress ? 1 : 0)
            assignButtons(CGRect(x: textX, y: top + detailsHeight - 62, width: details, height: 62), large: true, opacity: showsTransport ? 1 : 0)
            result.contentHeight = max(height, top + detailsHeight + 24)
        }
        // Hidden decorations retain meaningful geometry as they fade away;
        // they never collapse toward a one-point origin during a mode change.
        if result[.coverBackdrop].opacity == 0 {
            result[.coverBackdrop] = PlayerCanvasNode(frame: result[.artwork].frame, opacity: 0)
        }
        if result[.lyricSummary].opacity == 0 {
            let metadata = result[.metadata].frame
            result[.lyricSummary] = PlayerCanvasNode(frame: CGRect(x: metadata.minX, y: metadata.maxY + 12,
                width: metadata.width, height: 34), opacity: 0)
        }
        self.pose = result
    }
}
