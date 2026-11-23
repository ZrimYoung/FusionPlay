import Foundation

/// A caption from the current source document only. No lookup or metadata write.
enum PlayerCurrentLyricSummary {
    static func text(document: LyricsDocument, positionMs: UInt64?) -> String? {
        guard !document.lines.isEmpty else { return nil }
        let index: Int
        if document.isTimed {
            guard let positionMs, let active = document.activeLineIndex(at: positionMs) else { return nil }
            index = active
        } else { index = 0 }
        let text = document.lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "•••" : text.replacingOccurrences(of: "\n", with: " ")
    }
}
