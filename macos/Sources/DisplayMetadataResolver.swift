import Foundation

/// Display-only metadata. These values must never replace a Snapshot or the
/// track identity/title used by playback and seek commands.
struct DisplayMetadata: Equatable, Sendable {
    let title: String
    let artist: String
    let album: String
    let wasCorrected: Bool

    init(title: String, artist: String, album: String, wasCorrected: Bool = false) {
        self.title = title; self.artist = artist; self.album = album
        self.wasCorrected = wasCorrected
    }
}

/// Opt-in recovery from metadata already supplied with the current track.
/// No history, network lookup, persistence or diagnostic logging is involved.
enum DisplayMetadataResolver {
    private static let maximumMetadataCharacters = 512
    private static let delimiters: Set<Character> = ["-", "–", "—"]
    private static let wordPattern = try! NSRegularExpression(
        pattern: #"\p{L}[\p{L}\p{M}\p{N}]*(?:['-][\p{L}\p{M}\p{N}]+)*"#)

    static func resolve(title: String, artist: String, album: String, lyricsText: String) -> DisplayMetadata {
        let original = DisplayMetadata(title: title, artist: artist, album: album)
        guard !lyricsText.isEmpty, lyricsText.utf8.count <= LyricsDocument.maxSourceBytes else { return original }
        let headers = readHeaders(lyricsText)
        guard !headers.conflicts.contains("ti"), !headers.conflicts.contains("ar") else { return original }
        let knownTitle = headers.values["ti"]
        let knownArtist = headers.values["ar"]
        guard knownTitle != nil || knownArtist != nil else { return original }
        let composite = recoverComposite(artist: artist, album: album, knownTitle: knownTitle,
                                         knownArtist: knownArtist, knownAlbum: headers.values["al"])
        guard let realTitle = knownTitle ?? composite?.title else { return original }
        let alreadyCorrect = equivalent(title, realTitle)
        if !alreadyCorrect && !trim(title).isEmpty {
            let document = LyricsDocument(lyricsText)
            guard matchesTimedCaption(title, document: document) else { return original }
        }
        // Keep a genuine title's spelling/case, even when the same words also
        // appear in the chorus. Only an independently verified composite field
        // can still be cleaned in that case.
        let resolvedTitle = alreadyCorrect ? title : realTitle
        var resolvedArtist = artist
        if let composite { resolvedArtist = composite.artist }
        else if trim(artist).isEmpty, let knownArtist { resolvedArtist = knownArtist }
        let resolvedAlbum = trim(album).isEmpty ? (headers.values["al"] ?? album) : album
        let corrected = resolvedTitle != title || resolvedArtist != artist || resolvedAlbum != album
        return DisplayMetadata(title: resolvedTitle, artist: resolvedArtist, album: resolvedAlbum,
                               wasCorrected: corrected)
    }

    /// Prefer the protocol projection when supplied. An explicit empty value
    /// is meaningful; only a source with no projection uses the legacy resolver.
    static func resolveProjected(title: String, artist: String, album: String, lyricsText: String,
                                 displayTitle: String?, displayArtist: String?, displayAlbum: String?,
                                 correctLyricTitles: Bool = true) -> DisplayMetadata {
        let raw = DisplayMetadata(title: title, artist: artist, album: album)
        guard correctLyricTitles else { return raw }
        guard displayTitle != nil || displayArtist != nil || displayAlbum != nil else {
            return resolve(title: title, artist: artist, album: album, lyricsText: lyricsText)
        }
        let resolvedTitle = displayTitle ?? title
        let resolvedArtist = displayArtist ?? artist
        let resolvedAlbum = displayAlbum ?? album
        return DisplayMetadata(title: resolvedTitle, artist: resolvedArtist, album: resolvedAlbum,
                               wasCorrected: resolvedTitle != title || resolvedArtist != artist || resolvedAlbum != album)
    }

    private struct Headers {
        var values: [String: String] = [:]
        var conflicts = Set<String>()
    }
    private static func readHeaders(_ source: String) -> Headers {
        var headers = Headers()
        for raw in source.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).prefix(LyricsDocument.maxLines * 2) {
            var body = trim(String(raw.prefix(LyricsDocument.maxLineCharacters)))[...]
            // Only metadata at the beginning of a line is evidence. A lyric
            // containing a literal [ti:...] after its timestamp is not a header.
            while body.first == "[", let end = body.firstIndex(of: "]") {
                let token = body[body.index(after: body.startIndex)..<end]
                guard let colon = token.firstIndex(of: ":") else { break }
                let key = trim(String(token[..<colon])).lowercased()
                guard ["ti", "ar", "al"].contains(key) else { break }
                let value = trim(String(token[token.index(after: colon)...]))
                if !value.isEmpty, value.count <= maximumMetadataCharacters,
                   !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                    if let previous = headers.values[key], !equivalent(previous, value) {
                        headers.values.removeValue(forKey: key); headers.conflicts.insert(key)
                    } else if !headers.conflicts.contains(key) { headers.values[key] = value }
                }
                body = body[body.index(after: end)...]
            }
        }
        return headers
    }

    private struct Composite {
        let title: String
        let artist: String
    }
    private static func recoverComposite(artist: String, album: String, knownTitle: String?,
                                         knownArtist: String?, knownAlbum: String?) -> Composite? {
        var variants = [trim(artist)]
        // The display subtitle already appends Snapshot.album. Some senders
        // also include it inside artist; remove only an exact known suffix.
        for suffix in [album, knownAlbum ?? ""] where !trim(suffix).isEmpty {
            if let stripped = removingKnownSuffix(suffix, from: trim(artist)), !variants.contains(stripped) {
                variants.append(stripped)
            }
        }
        var candidates: [Composite] = []
        for value in variants where !value.isEmpty {
            if let knownTitle, let tail = removingKnownPrefix(knownTitle, from: value),
               knownArtist == nil || equivalent(tail, knownArtist!) {
                candidates.append(Composite(title: knownTitle, artist: knownArtist ?? tail))
            }
            if let knownArtist, let head = removingKnownSuffix(knownArtist, from: value),
               knownTitle == nil || equivalent(head, knownTitle!) {
                candidates.append(Composite(title: knownTitle ?? head, artist: knownArtist))
            }
        }
        guard let first = candidates.first,
              candidates.allSatisfy({ equivalent($0.title, first.title) && equivalent($0.artist, first.artist) }) else { return nil }
        return first
    }
    private static func removingKnownPrefix(_ prefix: String, from value: String) -> String? {
        let prefix = trim(prefix)
        guard !prefix.isEmpty,
              let range = value.range(of: prefix, options: [.anchored, .caseInsensitive, .widthInsensitive]) else { return nil }
        let remainder = trim(String(value[range.upperBound...]))
        guard let separator = remainder.first, delimiters.contains(separator) else { return nil }
        let tail = trim(String(remainder.dropFirst()))
        guard !tail.isEmpty, tail.count <= maximumMetadataCharacters else { return nil }
        return tail
    }
    private static func removingKnownSuffix(_ suffix: String, from value: String) -> String? {
        let suffix = trim(suffix)
        guard !suffix.isEmpty,
              let range = value.range(of: suffix, options: [.anchored, .backwards, .caseInsensitive, .widthInsensitive]) else { return nil }
        let remainder = trim(String(value[..<range.lowerBound]))
        guard let separator = remainder.last, delimiters.contains(separator) else { return nil }
        let head = trim(String(remainder.dropLast()))
        guard !head.isEmpty, head.count <= maximumMetadataCharacters else { return nil }
        return head
    }

    private static func matchesTimedCaption(_ title: String, document: LyricsDocument) -> Bool {
        let phrase = normalized(title)
        guard !phrase.isEmpty, phrase.count <= maximumMetadataCharacters else { return false }
        let cjkCount = phrase.unicodeScalars.filter(isCJK).count
        let words = wordPattern.matches(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)).filter { match in
            guard let range = Range(match.range, in: phrase) else { return false }
            let scalars = phrase[range].unicodeScalars
            return scalars.contains(where: { CharacterSet.letters.contains($0) && !isCJK($0) })
                && !scalars.contains(where: isCJK)
        }.count
        guard words >= 2 || cjkCount >= 4 else { return false }
        for line in document.lines where line.timeMs != nil {
            let rows = [line.text] + (line.translation?.components(separatedBy: "\n") ?? [])
            for source in rows {
                let row = normalized(source)
                var start = row.startIndex
                while start < row.endIndex,
                      let range = row.range(of: phrase, range: start..<row.endIndex) {
                    if hasBoundaries(range, in: row, phrase: phrase) { return true }
                    start = row.index(after: range.lowerBound)
                }
            }
        }
        return false
    }
    private static func hasBoundaries(_ range: Range<String.Index>, in row: String, phrase: String) -> Bool {
        if let first = phrase.first, isNonCJKWord(first), range.lowerBound > row.startIndex {
            let previous = row.index(before: range.lowerBound)
            if isWord(row[previous]) { return false }
            if isWordConnector(row[previous]), previous > row.startIndex,
               isWord(row[row.index(before: previous)]) { return false }
        }
        if let last = phrase.last, isNonCJKWord(last), range.upperBound < row.endIndex {
            if isWord(row[range.upperBound]) { return false }
            let next = row.index(after: range.upperBound)
            if isWordConnector(row[range.upperBound]), next < row.endIndex, isWord(row[next]) { return false }
        }
        return true
    }
    private static func isWordConnector(_ character: Character) -> Bool { character == "-" || character == "'" }
    private static func isWord(_ character: Character) -> Bool {
        character == "_" || character.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
    }
    private static func isNonCJKWord(_ character: Character) -> Bool {
        isWord(character) && !character.unicodeScalars.contains(where: isCJK)
    }
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF,
             0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF:
            return true
        default: return false
        }
    }
    private static func trim(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }
    private static func normalized(_ value: String) -> String {
        trim(value).precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "’", with: "'")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool { normalized(lhs) == normalized(rhs) }
}

/// One transient entry avoids parsing the LRC on every timeline/UI tick.
/// It is cleared with the media session; no values are persisted.
@MainActor final class DisplayMetadataCache {
    private struct Input: Equatable {
        let title: String
        let artist: String
        let album: String
        let lyricsText: String
        let displayTitle: String?
        let displayArtist: String?
        let displayAlbum: String?
    }
    private var previous: Input?
    private var result: DisplayMetadata?
    func resolve(title: String, artist: String, album: String, lyricsText: String,
                 displayTitle: String? = nil, displayArtist: String? = nil, displayAlbum: String? = nil) -> DisplayMetadata {
        let input = Input(title: title, artist: artist, album: album, lyricsText: lyricsText,
                          displayTitle: displayTitle, displayArtist: displayArtist, displayAlbum: displayAlbum)
        if previous == input, let result { return result }
        let resolved = DisplayMetadataResolver.resolveProjected(title: title, artist: artist, album: album, lyricsText: lyricsText,
            displayTitle: displayTitle, displayArtist: displayArtist, displayAlbum: displayAlbum)
        previous = input; result = resolved
        return resolved
    }
    func reset() { previous = nil; result = nil }
}
