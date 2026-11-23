import AppKit
import CoreText

/// Shapes the complete source line before dividing its original glyph runs
/// into independently movable word fragments. Substrings are never reshaped.
struct LyricsWordLayout: Equatable {
    let text: String
    let font: NSFont
    let lineSpacing: CGFloat
    let width: CGFloat
    let height: CGFloat
    let lineEnds: [Int]
    let fragments: [Fragment]
    var isRasterComplete: Bool { fragments.allSatisfy { $0.image != nil } }

    struct Fragment: Identifiable, Equatable {
        let id: String
        let lineIndex: Int
        /// UTF-16 coverage of this shaped fragment, excluding whitespace.
        let sourceRange: NSRange
        /// Canonical token range, determined before width-dependent wrapping.
        let wordRange: NSRange
        /// Top-left coordinates in the lyric's line box, including ink bleed.
        let frame: CGRect
        let image: NSImage?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.lineIndex == rhs.lineIndex && lhs.sourceRange == rhs.sourceRange &&
                lhs.wordRange == rhs.wordRange && lhs.frame == rhs.frame && (lhs.image != nil) == (rhs.image != nil)
        }
    }

    private struct Token { let range: NSRange }
    private struct Glyph {
        let font: CTFont
        let fontIdentity: String
        let runID: Int
        let glyph: CGGlyph
        let position: CGPoint // original glyph position in full-text y-up coordinates
        let sourceIndex: Int
        let ink: CGRect
    }
    private struct Slice {
        let token: Token
        let lineIndex: Int
        var sourceRange: NSRange
        var glyphs: [Glyph]
    }
    private struct RasterKey: Hashable {
        let fonts: [String]
        let glyphs: [CGGlyph]
        let fontIndices: [Int]
        let coordinates: [Int]
    }
    private struct CachedRaster {
        let image: CGImage
        let pixels: Int
    }
    @MainActor private static var rasterCache: [RasterKey: CachedRaster] = [:]
    @MainActor private static var cachePixels = 0
    private static let maximumCachePixels = 4_000_000
    private static let maximumCacheEntries = 256

    @MainActor static var cacheStatistics: (entries: Int, pixels: Int) { (rasterCache.count, cachePixels) }
    @MainActor static func clearCache() { rasterCache.removeAll(keepingCapacity: true); cachePixels = 0 }

    @MainActor static func measure(text: String, font: NSFont, lineSpacing: CGFloat, width: CGFloat) -> Self {
        let width = width.isFinite ? max(1, width) : 1
        let spacing = lineSpacing.isFinite ? max(0, lineSpacing) : 0
        guard !text.isEmpty else {
            return Self(text: text, font: font, lineSpacing: spacing, width: width,
                        height: 0, lineEnds: [], fragments: [])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .natural
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let source = text as NSString
        let tokens = canonicalTokens(in: text)
        var offset = 0, y: CGFloat = 0, lineIndex = 0, runID = 0
        var ends: [Int] = [], slices: [Slice] = []
        while offset < source.length {
            let proposed = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
            let count = min(source.length - offset, proposed > 0 ? proposed : source.rangeOfComposedCharacterSequence(at: offset).length)
            let range = CFRange(location: offset, length: max(1, count))
            let line = CTTypesetterCreateLine(typesetter, range)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            if ascent + descent == 0 { ascent = font.ascender; descent = -font.descender; leading = font.leading }
            let lineHeight = max(1, ascent + descent + max(0, leading))
            let baseline = y + ascent + max(0, leading) * 0.5
            var glyphs: [Glyph] = []
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let rawFont = attributes[kCTFontAttributeName] else { continue }
                let nativeFont = rawFont as! CTFont
                let nativeIdentity = fontIdentity(nativeFont, baseSize: max(1, font.pointSize))
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                var ids = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                var bounds = [CGRect](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &ids)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                CTFontGetBoundingRectsForGlyphs(nativeFont, .default, ids, &bounds, count)
                for index in 0..<count {
                    let sourceIndex = indices[index] == kCFNotFound ? CTRunGetStringRange(run).location : indices[index]
                    let position = CGPoint(x: positions[index].x, y: positions[index].y - baseline)
                    let ink = bounds[index].offsetBy(dx: position.x, dy: position.y)
                    glyphs.append(Glyph(font: nativeFont, fontIdentity: nativeIdentity, runID: runID, glyph: ids[index],
                                        position: position, sourceIndex: sourceIndex, ink: ink))
                }
                runID += 1
            }
            // Logical UTF-16 cluster coverage is independent of visual bidi order.
            let clusterStarts = Array(Set(glyphs.map(\.sourceIndex).filter { $0 >= offset && $0 < offset + range.length } + [offset + range.length])).sorted()
            var clusterEnds: [Int: Int] = [:]
            for pair in zip(clusterStarts, clusterStarts.dropFirst()) { clusterEnds[pair.0] = pair.1 }
            var byToken: [Int: Slice] = [:]
            for glyph in glyphs {
                guard !glyph.ink.isNull, !glyph.ink.isInfinite,
                      glyph.ink.width > 0, glyph.ink.height > 0,
                      let tokenIndex = tokenIndex(containing: glyph.sourceIndex, tokens: tokens) else { continue }
                let token = tokens[tokenIndex]
                let start = max(token.range.location, glyph.sourceIndex)
                let end = min(NSMaxRange(token.range), clusterEnds[glyph.sourceIndex] ?? (glyph.sourceIndex + 1))
                let sourceRange = NSRange(location: start, length: max(1, end - start))
                if var slice = byToken[tokenIndex] {
                    slice.sourceRange = NSUnionRange(slice.sourceRange, sourceRange)
                    slice.glyphs.append(glyph); byToken[tokenIndex] = slice
                } else {
                    byToken[tokenIndex] = Slice(token: token, lineIndex: lineIndex, sourceRange: sourceRange, glyphs: [glyph])
                }
            }
            slices.append(contentsOf: byToken.values.sorted { $0.sourceRange.location < $1.sourceRange.location })
            offset += range.length; ends.append(offset)
            y += lineHeight + spacing; lineIndex += 1
        }
        if text.hasSuffix("\n") || text.hasSuffix("\r") {
            ends.append(source.length)
            y += max(1, font.ascender - font.descender + font.leading) + spacing
        }
        let height = max(0, ceil(y - spacing))
        let baseSize = max(1, font.pointSize)
        let bleed = max(0.5, min(3, baseSize * 0.08))
        let pixelScale = max(1, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let fragments = slices.map { slice -> Fragment in
            let ink = slice.glyphs.reduce(CGRect.null) { $0.union($1.ink) }
            let left = floor((ink.minX - bleed) * pixelScale) / pixelScale
            let top = floor((-ink.maxY - bleed) * pixelScale) / pixelScale
            let right = ceil((ink.maxX + bleed) * pixelScale) / pixelScale
            let bottom = ceil((-ink.minY + bleed) * pixelScale) / pixelScale
            let frame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            return Fragment(id: "\(slice.token.range.location):\(slice.sourceRange.location)",
                            lineIndex: slice.lineIndex, sourceRange: slice.sourceRange, wordRange: slice.token.range,
                            frame: frame, image: raster(glyphs: slice.glyphs, frame: frame, baseSize: baseSize, pixelScale: pixelScale))
        }
        return Self(text: text, font: font, lineSpacing: spacing, width: width, height: height,
                    lineEnds: ends, fragments: fragments)
    }

    /// Foundation words plus non-whitespace composed gaps retain punctuation,
    /// flags and ZWJ emoji without assigning new IDs after rewrapping.
    private static func canonicalTokens(in text: String) -> [Token] {
        var words: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, range, _, _ in
            words.append(NSRange(range, in: text))
        }
        let source = text as NSString
        var result: [Token] = [], cursor = 0
        func appendGap(until end: Int) {
            while cursor < end {
                let composed = source.rangeOfComposedCharacterSequence(at: cursor)
                let range = NSRange(location: cursor, length: min(NSMaxRange(composed), end) - cursor)
                if !source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Token(range: range))
                }
                cursor = NSMaxRange(range)
            }
        }
        for word in words.sorted(by: { $0.location < $1.location }) {
            guard word.location >= cursor else { continue }
            appendGap(until: word.location)
            result.append(Token(range: word)); cursor = NSMaxRange(word)
        }
        appendGap(until: source.length)
        return result
    }

    private static func tokenIndex(containing index: Int, tokens: [Token]) -> Int? {
        var low = 0, high = tokens.count
        while low < high {
            let mid = (low + high) / 2, range = tokens[mid].range
            if index < range.location { high = mid }
            else if index >= NSMaxRange(range) { low = mid + 1 }
            else { return mid }
        }
        return nil
    }

    private static func fontIdentity(_ font: CTFont, baseSize: CGFloat) -> String {
        let traits = CTFontCopyTraits(font) as NSDictionary
        let variation = CTFontCopyVariation(font).map { ($0 as NSDictionary).description } ?? ""
        let optical = CTFontCopyAttribute(font, kCTFontOpticalSizeAttribute).map { String(describing: $0) } ?? ""
        let matrix = CTFontGetMatrix(font)
        return [CTFontCopyPostScriptName(font) as String,
                String(describing: traits), variation, optical,
                String(format: "%.6f", CTFontGetSize(font) / baseSize),
                "\(matrix.a),\(matrix.b),\(matrix.c),\(matrix.d),\(matrix.tx),\(matrix.ty)"].joined(separator: "|")
    }

    @MainActor private static func raster(glyphs: [Glyph], frame: CGRect, baseSize: CGFloat, pixelScale: CGFloat) -> NSImage? {
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return nil }
        let normalizedWidth = frame.width / baseSize, normalizedHeight = frame.height / baseSize
        var fonts: [String] = [], fontIndices: [Int] = [], coordinates: [Int] = []
        var fontLookup: [String: Int] = [:]
        for glyph in glyphs {
            let identity = glyph.fontIdentity
            let index: Int
            if let cached = fontLookup[identity] { index = cached }
            else { index = fonts.count; fontLookup[identity] = index; fonts.append(identity) }
            fontIndices.append(index)
            coordinates.append(Int(((glyph.position.x - frame.minX) / baseSize * 2048).rounded()))
            coordinates.append(Int(((glyph.position.y + frame.maxY) / baseSize * 2048).rounded()))
        }
        coordinates.append(Int((normalizedWidth * 2048).rounded()))
        coordinates.append(Int((normalizedHeight * 2048).rounded()))
        coordinates.append(Int((baseSize * 2048).rounded()))
        coordinates.append(Int((pixelScale * 2048).rounded()))
        let key = RasterKey(fonts: fonts, glyphs: glyphs.map(\.glyph), fontIndices: fontIndices, coordinates: coordinates)
        if let cached = rasterCache[key] { return NSImage(cgImage: cached.image, size: frame.size) }

        // Rasterize the original font at display density. Color bitmap fonts
        // do not reliably honor CTFont matrices; em normalization would shrink
        // emoji. Device-aligned canvases also avoid settled-text resampling.
        let canonical: CGFloat = baseSize
        let canonicalWidth = normalizedWidth * canonical, canonicalHeight = normalizedHeight * canonical
        let density = max(0.01, min(pixelScale, 4096 / max(canonicalWidth, canonicalHeight),
                                    sqrt(1_000_000 / max(1, canonicalWidth * canonicalHeight))))
        let pixelsWide = max(1, Int(ceil(canonicalWidth * density)))
        let pixelsHigh = max(1, Int(ceil(canonicalHeight * density)))
        guard pixelsWide <= 4096, pixelsHigh <= 4096,
              pixelsWide * pixelsHigh <= 1_010_000,
              let context = CGContext(data: nil, width: pixelsWide, height: pixelsHigh,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: density, y: density)
        context.setFillColor(NSColor.white.cgColor)
        context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
        var index = 0
        while index < glyphs.count {
            let runID = glyphs[index].runID
            var end = index + 1
            while end < glyphs.count && glyphs[end].runID == runID { end += 1 }
            let segment = glyphs[index..<end]
            let original = glyphs[index].font
            let scale = canonical / baseSize
            let ids = segment.map(\.glyph)
            let positions = segment.map {
                CGPoint(x: ($0.position.x - frame.minX) * scale,
                        y: ($0.position.y + frame.maxY) * scale)
            }
            CTFontDrawGlyphs(original, ids, positions, ids.count, context)
            index = end
        }
        guard let image = context.makeImage() else { return nil }
        let pixels = pixelsWide * pixelsHigh
        if rasterCache.count >= maximumCacheEntries || cachePixels + pixels > maximumCachePixels {
            clearCache()
        }
        if pixels <= maximumCachePixels {
            rasterCache[key] = CachedRaster(image: image, pixels: pixels); cachePixels += pixels
        }
        return NSImage(cgImage: image, size: frame.size)
    }
}
