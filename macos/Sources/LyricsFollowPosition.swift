/// The phone can omit progress in a partial metadata update. Absence is not a
/// seek to zero: retain the last real position until a new value or disconnect.
/// A real track change creates a new LyricsView identity and a fresh instance.
struct LyricsFollowPosition: Equatable {
    private(set) var lastPositionMs: UInt64?

    mutating func observe(_ positionMs: UInt64?, connected: Bool) {
        guard connected else { lastPositionMs = nil; return }
        if let positionMs { lastPositionMs = positionMs }
    }

    func current(_ positionMs: UInt64?, connected: Bool) -> UInt64? {
        guard connected else { return nil }
        return positionMs ?? lastPositionMs
    }
}
