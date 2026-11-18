import Foundation

struct LyricsLine: Identifiable, Equatable, Sendable {
    let id: Int
    let timeMs: UInt64?
    let text: String
    let translation: String?
}

/// A bounded, immutable LRC document. Untimed text remains readable without
/// inventing synchronization; timed blanks mark instrumental gaps.
struct LyricsDocument: Equatable, Sendable {
    static let maxSourceBytes = 256 * 1024
    static let maxLines = 4_000
    static let maxLineCharacters = 2_048
    static let maxTranslationCharacters = 4_096
    static let maxTimestampMs: Int64 = 24 * 60 * 60 * 1_000

    let lines: [LyricsLine]
    var isTimed: Bool { lines.first?.timeMs != nil }

    init(_ source: String) {
        let bounded = String(decoding: source.utf8.prefix(Self.maxSourceBytes), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var timed: [(time: Int64, text: String, order: Int)] = []
        var plain: [String] = []
        var offset: Int64 = 0
        for raw in bounded.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.maxLines * 2) {
            let clipped = String(raw.prefix(Self.maxLineCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
            var body = clipped[...]
            var timestamps: [Int64] = []
            while body.first == "[", let end = body.firstIndex(of: "]") {
                let token = String(body[body.index(after: body.startIndex)..<end])
                if let time = Self.timestamp(token) {
                    if timestamps.count < 64 { timestamps.append(time) }
                } else if let value = Self.offset(token) {
                    offset = value
                } else if !Self.isMetadata(token) && !Self.looksLikeTimestamp(token) {
                    break
                }
                body = body[body.index(after: end)...]
            }
            let text = Self.cleanText(String(body))
            if !timestamps.isEmpty {
                for time in timestamps where timed.count < Self.maxLines {
                    timed.append((time, text, timed.count))
                }
            } else if !text.isEmpty && plain.count < Self.maxLines {
                plain.append(text)
            }
        }
        guard !timed.isEmpty else {
            lines = plain.enumerated().map { LyricsLine(id: $0.offset, timeMs: nil, text: $0.element, translation: nil) }
            return
        }
        // Timestamp-only payloads contain no displayable lyrics. Retain gap
        // markers only when there is at least one real lyric line in the document.
        guard timed.contains(where: { !$0.text.isEmpty }) else { lines = []; return }
        // LRC's positive offset advances lyrics; negative delays them. Apply
        // once after parsing, since the header can occur after lyric lines.
        timed = timed.map { (min(Self.maxTimestampMs, max(0, $0.time - offset)), $0.text, $0.order) }
            .sorted { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var result: [LyricsLine] = []
        var groupTime: Int64?
        var group: [String] = []
        func appendGroup() {
            guard let time = groupTime else { return }
            let words = group.filter { !$0.isEmpty }
            let translation = String(words.dropFirst().joined(separator: "\n").prefix(Self.maxTranslationCharacters))
            result.append(LyricsLine(id: result.count, timeMs: UInt64(time), text: words.first ?? "",
                                     translation: translation.isEmpty ? nil : translation))
        }
        for entry in timed {
            if groupTime != entry.time {
                appendGroup(); groupTime = entry.time; group = []
            }
            // Duplicate timestamp rows are commonly original + translation.
            // Keep source order and avoid repeating identical text.
            if group.count < 16 && !group.contains(entry.text) { group.append(entry.text) }
        }
        appendGroup()
        lines = result
    }

    /// Latest timestamp at or before the position. No row is active before the
    /// first line, or when the phone supplied only untimed text.
    func activeLineIndex(at positionMs: UInt64) -> Int? {
        guard isTimed, let first = lines.first?.timeMs, positionMs >= first else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let middle = low + (high - low) / 2
            if let time = lines[middle].timeMs, time <= positionMs { low = middle + 1 }
            else { high = middle }
        }
        return low - 1
    }

    private static func timestamp(_ token: String) -> Int64? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...4).contains(parts[0].utf8.count), digits(parts[0]),
              let minutes = Int64(parts[0]) else { return nil }
        let seconds = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(seconds.count), seconds[0].utf8.count == 2, digits(seconds[0]),
              let whole = Int64(seconds[0]), whole < 60 else { return nil }
        var milliseconds: Int64 = 0
        if seconds.count == 2 {
            let fraction = seconds[1]
            guard (1...3).contains(fraction.utf8.count), digits(fraction), let value = Int64(fraction) else { return nil }
            milliseconds = value * (fraction.utf8.count == 1 ? 100 : fraction.utf8.count == 2 ? 10 : 1)
        }
        let value = (minutes * 60 + whole) * 1_000 + milliseconds
        return value <= maxTimestampMs ? value : nil
    }
    private static func digits(_ value: Substring) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
    private static func offset(_ token: String) -> Int64? {
        guard token.lowercased().hasPrefix("offset:") else { return nil }
        let value = token.dropFirst(7).trimmingCharacters(in: .whitespaces)
        guard let number = Int64(value) else { return nil }
        return min(maxTimestampMs, max(-maxTimestampMs, number))
    }
    private static func isMetadata(_ token: String) -> Bool {
        guard let colon = token.firstIndex(of: ":") else { return false }
        let key = token[..<colon].lowercased()
        return ["ar", "al", "ti", "au", "by", "re", "ve", "length", "offset", "id", "tool"].contains(key)
    }
    private static func looksLikeTimestamp(_ token: String) -> Bool {
        guard let first = token.utf8.first else { return false }
        return first >= 48 && first <= 57 && token.contains(":")
    }
    private static func cleanText(_ source: String) -> String {
        // Enhanced LRC word timestamps are not exposed as literal angle tags;
        // this version highlights complete lines rather than individual words.
        let text = source.replacingOccurrences(of: #"<\d{1,4}:\d{2}(?:\.\d{1,3})?>"#,
                                               with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
