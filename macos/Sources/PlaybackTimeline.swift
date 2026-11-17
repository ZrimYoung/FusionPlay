import Foundation

// UI-only feedback. The receiver and system media always retain source-reported time.
struct PlaybackObservation: Equatable {
    var trackID: String
    var title: String
    var duration: UInt64?
    var position: UInt64?
    var connected: Bool
    var playing: Bool
    var canSeek: Bool { connected && (duration ?? 0) > 0 && position != nil }
    func sameTrack(as other: Self) -> Bool {
        let identityMatches = !trackID.isEmpty || !other.trackID.isEmpty
            ? !trackID.isEmpty && trackID == other.trackID
            : title == other.title
        return connected && other.connected && identityMatches && duration == other.duration
    }
}

struct PlaybackTimeline {
    static let timeout: TimeInterval = 5
    private struct Pending {
        let token: UInt64
        let source: PlaybackObservation
        let target: UInt64
        let started: TimeInterval
    }
    private(set) var source: PlaybackObservation?
    private var pending: Pending?
    private var sequence: UInt64 = 0
    var pendingToken: UInt64? { pending?.token }
    var isPending: Bool { pending != nil }
    func displayPosition(now: TimeInterval) -> UInt64? {
        if let pending, let source, pending.source.sameTrack(as: source), now - pending.started < Self.timeout {
            return pending.target
        }
        return source?.position
    }
    mutating func observe(_ observation: PlaybackObservation, now: TimeInterval) {
        source = observation
        guard let value = pending else { return }
        guard value.source.sameTrack(as: observation), observation.canSeek,
              now - value.started < Self.timeout else { pending = nil; return }
        guard let position = observation.position, let baseline = value.source.position,
              distance(position, value.target) <= 2_000 else { return }
        if value.target == baseline { pending = nil; return }
        if position == baseline { return }
        if value.target < baseline {
            if position <= value.target || baseline - min(baseline, position) > 250 { pending = nil }
        } else {
            let elapsed = value.source.playing ? UInt64(max(0, min(Self.timeout, now - value.started)) * 1000) : 0
            let allowance = elapsed + 250
            let naturalCeiling = baseline > UInt64.max - allowance ? UInt64.max : baseline + allowance
            if position >= value.target || position > naturalCeiling { pending = nil }
        }
    }
    mutating func begin(target: UInt64, now: TimeInterval) -> UInt64? {
        guard let source, source.canSeek, let duration = source.duration, target <= duration else { return nil }
        sequence &+= 1
        pending = Pending(token: sequence, source: source, target: target, started: now)
        return sequence
    }
    @discardableResult mutating func complete(_ token: UInt64, dispatched: Bool) -> Bool {
        guard pending?.token == token else { return false }
        if !dispatched { pending = nil }
        return true
    }
    @discardableResult mutating func expire(_ token: UInt64, now: TimeInterval) -> Bool {
        guard let pending, pending.token == token, now - pending.started >= Self.timeout else { return false }
        self.pending = nil
        return true
    }
    mutating func cancel() { pending = nil }
    private func distance(_ left: UInt64, _ right: UInt64) -> UInt64 {
        left >= right ? left - right : right - left
    }
}
