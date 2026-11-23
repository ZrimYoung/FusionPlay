import AppKit
import CoreText

@main struct LyricsWordLayoutSmoke {
    @MainActor static func main() throws {
        let font = NSFont.systemFont(ofSize: 34, weight: .bold)
        let text = "A quiet morning brings another changing light across the mountains and the sea"
        let wide = LyricsWordLayout.measure(text: text, font: font, lineSpacing: 3, width: 620)
        let narrow = LyricsWordLayout.measure(text: text, font: font, lineSpacing: 3, width: 230)
        precondition(narrow.lineEnds.count > wide.lineEnds.count && narrow.height > wide.height)
        let words = Set(wide.fragments.map(\.wordRange))
        precondition(Set(narrow.fragments.map(\.wordRange)) == words,
                     "Width changed canonical word identity")
        precondition(wide.fragments.contains { first in
            narrow.fragments.contains { $0.id == first.id && $0.lineIndex != first.lineIndex }
        }, "Fixture did not move words across lines")
        let sources = [
            text,
            "office affine ffi, punctuation!",
            "\u{4e2d}\u{6587}\u{6b4c}\u{8bcd}\u{ff0c}\u{65e5}\u{672c}\u{8a9e}\u{3002} \u{d55c}\u{ad6d}\u{c5b4}",
            "Music \u{1f3b5} \u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} \u{1f1e8}\u{1f1f3}",
            "\u{0645}\u{0648}\u{0633}\u{064a}\u{0642}\u{0649} \u{05e9}\u{05dc}\u{05d5}\u{05dd} hello",
            "First line\nSecond line\n",
            "supercalifragilisticexpialidocious"
        ]
        var cases = 0, visiblePixels = 0
        for source in sources {
            let utf16 = source as NSString
            for width in [1.0, 170.0, 320.0, 620.0] {
                let layout = LyricsWordLayout.measure(text: source, font: font, lineSpacing: 3, width: width)
                precondition(layout.lineEnds.last == source.utf16.count)
                precondition(layout.height.isFinite && layout.height > 0 && layout.isRasterComplete)
                precondition(Set(layout.fragments.map(\.id)).count == layout.fragments.count)
                for part in layout.fragments {
                    precondition(part.frame.minX.isFinite && part.frame.minY.isFinite && part.frame.width > 0 && part.frame.height > 0)
                    precondition(part.sourceRange.location >= part.wordRange.location && NSMaxRange(part.sourceRange) <= NSMaxRange(part.wordRange))
                    guard let image = part.image,
                          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let data = cg.dataProvider?.data else { fatalError("Missing word raster") }
                    let bytes = CFDataGetBytePtr(data)!
                    let ink = stride(from: 3, to: CFDataGetLength(data), by: 4).filter { bytes[$0] > 8 }.count
                    precondition(ink > 0, "Invisible native glyph image for \(utf16.substring(with: part.sourceRange))")
                    visiblePixels += ink
                }
                // Every visible composed sequence must remain in a shaped
                // fragment, including ZWJ emoji, flags, punctuation and marks.
                source.enumerateSubstrings(in: source.startIndex..<source.endIndex, options: .byComposedCharacterSequences) { substring, range, _, _ in
                    guard let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                    let token = NSRange(range, in: source)
                    precondition(layout.fragments.contains { NSIntersectionRange($0.sourceRange, token).length == token.length },
                                 "Lost composed glyph coverage: \(substring)")
                }
                cases += 1
            }
        }
        let long = LyricsWordLayout.measure(text: String(repeating: "unbroken", count: 500), font: font, lineSpacing: 3, width: 1_800)
        precondition(long.isRasterComplete && long.fragments.count > 1)
        precondition(long.fragments.allSatisfy { $0.wordRange == NSRange(location: 0, length: 4_000) })
        let before = LyricsWordLayout.cacheStatistics
        _ = LyricsWordLayout.measure(text: text, font: font, lineSpacing: 3, width: 620)
        let afterFirst = LyricsWordLayout.cacheStatistics
        _ = LyricsWordLayout.measure(text: text, font: font, lineSpacing: 3, width: 620)
        let afterSecond = LyricsWordLayout.cacheStatistics
        precondition(afterFirst.entries == afterSecond.entries && afterFirst.pixels == afterSecond.pixels)
        precondition(before.entries <= 256 && before.pixels <= 4_000_000)
        precondition(afterSecond.entries <= 256 && afterSecond.pixels <= 4_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        for width in stride(from: 280.0, through: 600.0, by: 8) {
            _ = LyricsWordLayout.measure(text: text, font: font, lineSpacing: 3, width: width)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let current = LyricsWordLayout.cacheStatistics
        precondition(current.entries <= 256 && current.pixels <= 4_000_000)
        print("PASS: \(cases) native word layouts, UTF-16/grapheme coverage, bidi/ligature/emoji rasters, stable words, long-word fragments and bounded cache")
        print("Rendered ink pixels: \(visiblePixels); 41 fixed-font widths: \(String(format: "%.3f", elapsed))s; cache \(current.entries) entries / \(current.pixels) pixels")
    }
}
