import Foundation

@main struct LyricsSmoke {
    static func main() {
        let timed = LyricsDocument("[ar:Synthetic Artist]\n[00:10.50]Later\n[00:01.250][00:05.1]Opening\n[00:05.100]Translation\n[00:05.100]Translation")
        precondition(timed.isTimed && timed.lines.count == 3)
        precondition(timed.lines.map(\.timeMs) == [1_250, 5_100, 10_500])
        precondition(timed.lines[1].text == "Opening" && timed.lines[1].translation == "Translation")
        precondition(timed.lines.map(\.id) == [0, 1, 2])
        precondition(timed.activeLineIndex(at: 1_249) == nil)
        precondition(timed.activeLineIndex(at: 1_250) == 0)
        precondition(timed.activeLineIndex(at: 10_499) == 1)
        precondition(timed.activeLineIndex(at: UInt64.max) == 2)

        let advanced = LyricsDocument("[00:00.10]Opening\n[00:02.00]Next\n[offset:+500]")
        precondition(advanced.lines.map(\.timeMs) == [0, 1_500], "Positive offset must advance and clamp lyrics")
        let delayed = LyricsDocument("[offset:-125]\n[00:01]Delayed")
        precondition(delayed.lines.first?.timeMs == 1_125)
        let blank = LyricsDocument("[00:01]Opening\n[00:03]\n[00:06]Next")
        precondition(blank.lines.count == 3 && blank.lines[1].text.isEmpty && blank.activeLineIndex(at: 4_000) == 1,
                     "Timed blanks must end highlights across instrumental gaps")

        let plain = LyricsDocument("\u{FEFF}[ti:Synthetic]\r\n\r\nFirst line\rSecond line\n[Chorus]\n[offset:invalid]")
        precondition(!plain.isTimed && plain.lines.map(\.text) == ["First line", "Second line", "[Chorus]"])
        precondition(plain.activeLineIndex(at: 2_000) == nil)
        precondition(LyricsDocument("").lines.isEmpty)
        precondition(LyricsDocument("[00:00]\n[00:03]").lines.isEmpty)
        precondition(LyricsDocument("[ar:Artist]\n[by:Test]\n\n").lines.isEmpty)
        let malformed = LyricsDocument("[00:99.10]Invalid seconds\n[00:02.1234]Invalid fraction\n[99999:10]Overflow\n[00:01.23]Valid")
        precondition(malformed.lines.count == 1 && malformed.lines.first?.timeMs == 1_230)
        let enhanced = LyricsDocument("[00:01.00]<00:01.00>Word <00:01.50>timing")
        precondition(enhanced.lines.first?.text == "Word timing")

        let many = LyricsDocument((0..<(LyricsDocument.maxLines + 1)).map { "[\($0 / 60):\(String(format: "%02d", $0 % 60))]Line \($0)" }.joined(separator: "\n"))
        precondition(many.lines.count == LyricsDocument.maxLines)
        let oversized = LyricsDocument(String(repeating: "x", count: LyricsDocument.maxSourceBytes + 1))
        precondition(oversized.lines.count == 1 && oversized.lines[0].text.count <= LyricsDocument.maxLineCharacters)
        let duplicates = LyricsDocument((0..<30).map { "[00:01]Row \($0) " + String(repeating: "x", count: 400) }.joined(separator: "\n"))
        precondition(duplicates.lines.count == 1 && (duplicates.lines[0].translation?.count ?? 0) <= LyricsDocument.maxTranslationCharacters)
        let enormousOffset = LyricsDocument("[offset:-9999999999999999999999999999]\n[00:01]Safe")
        precondition(enormousOffset.lines.first?.timeMs == 1_000)
        print("PASS: bounded timed/untimed LRC, fractions, repeated timestamps, translations, metadata, signed offset, instrumental blanks, lookup and malformed input")
    }
}
