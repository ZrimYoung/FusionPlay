import AppKit
import CoreText
import SwiftUI

/// Only this local text frame changes height; it never publishes a window bound.
struct PlayerTrackMetadataView: View {
    @Environment(\.appTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("wrapPlayerMetadata") private var wraps = false
    let title: String
    let subtitle: String
    let width: CGFloat
    let titleSize: CGFloat
    let subtitleSize: CGFloat
    var spacing: CGFloat = 4
    var defaultTitleLines = 1
    var wrappedTitleLines = 3
    var wrappedSubtitleLines = 2
    var subtitleOpacity = 0.7
    var allowsSelection = false

    var body: some View {
        let height = Self.height(title: title, subtitle: subtitle, width: width,
                                 titleFont: typography.nsFont(size: titleSize, weight: .semibold),
                                 subtitleFont: typography.nsFont(size: subtitleSize), spacing: spacing,
                                 wraps: wraps, defaultTitleLines: defaultTitleLines,
                                 wrappedTitleLines: wrappedTitleLines, wrappedSubtitleLines: wrappedSubtitleLines)
        VStack(alignment: .leading, spacing: spacing) {
            titleText
            if !subtitle.isEmpty {
                Text(verbatim: subtitle).font(typography.font(size: subtitleSize))
                    .foregroundStyle(.white.opacity(subtitleOpacity))
                    .lineLimit(wraps ? wrappedSubtitleLines : 1).fixedSize(horizontal: false, vertical: true)
                    .help(subtitle).contentTransition(.opacity)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(width: max(0, width), alignment: .leading)
        .frame(minHeight: height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: height)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: subtitle.isEmpty)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var titleText: some View {
        let text = Text(verbatim: title).font(typography.font(size: titleSize, weight: .semibold))
            .lineLimit(wraps ? wrappedTitleLines : defaultTitleLines)
            .fixedSize(horizontal: false, vertical: true).help(title).contentTransition(.opacity)
        if allowsSelection { text.textSelection(.enabled) } else { text }
    }

    static func height(title: String, subtitle: String, width: CGFloat, titleFont: NSFont,
                       subtitleFont: NSFont, spacing: CGFloat, wraps: Bool,
                       defaultTitleLines: Int = 1, wrappedTitleLines: Int = 3, wrappedSubtitleLines: Int = 2) -> CGFloat {
        func measured(_ text: String, font: NSFont, lines: Int) -> CGFloat {
            let baseLineHeight = NSLayoutManager().defaultLineHeight(for: font)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let length = attributed.length
            var position = 0
            var height: CGFloat = 0
            for _ in 0..<lines where position < length {
                let count = max(1, CTTypesetterSuggestLineBreak(typesetter, position, Double(max(1, width))))
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: position, length: min(count, length - position)))
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                // The actual runs include CJK and other fallback fonts, whose
                // line height can exceed the selected Latin face's metrics.
                height += max(baseLineHeight, ascent + descent + leading)
                position += count
            }
            return ceil(max(baseLineHeight, height))
        }
        let titleHeight = measured(title, font: titleFont, lines: wraps ? wrappedTitleLines : defaultTitleLines)
        return titleHeight + (subtitle.isEmpty ? 0 : spacing + measured(subtitle, font: subtitleFont, lines: wraps ? wrappedSubtitleLines : 1))
    }
}
