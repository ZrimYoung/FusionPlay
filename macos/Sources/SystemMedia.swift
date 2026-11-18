import AppKit
import MediaPlayer

// Only source-supplied time is published. The system extrapolates while playing;
// diagnostic snapshots must not repeatedly reset that clock to an old position.
struct MediaPresentation: Equatable {
    let title: String
    let artist: String
    let album: String
    let trackID: String
    let artworkURL: String
    let duration: Double?
    let position: Double?
    let playing: Bool

    init?(_ state: Snapshot, previouslyActive: Bool = false, metadata: DisplayMetadata? = nil) {
        guard state.controlsAvailable,
              state.phase == .playing || state.phase == .paused ||
                (previouslyActive && state.phase == .connected) else { return nil }
        let labels = metadata ?? DisplayMetadata(title: state.title, artist: state.artist, album: state.album)
        title = labels.title.isEmpty ? "手机投送" : labels.title
        artist = labels.artist; album = labels.album; trackID = state.trackId
        artworkURL = state.artworkUrl
        let durationSeconds = state.durationMs.map { Double($0) / 1000 }
        duration = durationSeconds
        position = state.positionMs.map { min(Double($0) / 1000, durationSeconds ?? .greatestFiniteMagnitude) }
        playing = state.phase == .playing
    }
    var info: [String: Any] {
        var result: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        if !trackID.isEmpty { result[MPNowPlayingInfoPropertyExternalContentIdentifier] = trackID }
        if let duration { result[MPMediaItemPropertyPlaybackDuration] = duration }
        if let position { result[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position }
        return result
    }
}

// A seek from a system widget must still target the item selected when it was issued.
struct MediaSeekTrack: Equatable, Sendable {
    let id: String
    let fallbackTitle: String
    let duration: UInt64

    init?(_ state: Snapshot) {
        guard state.controlsAvailable, let duration = state.durationMs, duration > 0, state.positionMs != nil,
              !state.trackId.isEmpty || !state.title.isEmpty else { return nil }
        self.duration = duration
        id = state.trackId
        fallbackTitle = id.isEmpty ? state.title : ""
    }

    func request(at seconds: TimeInterval) -> MediaSeekRequest? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let milliseconds = min(Double(duration), (seconds * 1_000).rounded())
        return MediaSeekRequest(track: self, positionMs: UInt64(exactly: milliseconds) ?? duration)
    }
}

struct MediaSeekRequest: Sendable {
    let track: MediaSeekTrack
    let positionMs: UInt64

    func isCurrent(in state: Snapshot, canSeek: Bool) -> Bool {
        canSeek && MediaSeekTrack(state) == track
    }
}

// Remote-command callbacks need not arrive on the main thread. Take a small
// locked snapshot, enqueue the command and return immediately; never wait for
// a phone acknowledgement on the system callback thread.
final class MediaCommandGate: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    private var playing = false
    private var seekTrack: MediaSeekTrack?
    func update(enabled: Bool, playing: Bool, seekTrack: MediaSeekTrack? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled; self.playing = playing
        self.seekTrack = seekTrack
    }
    func resolveSeek(_ seconds: TimeInterval) -> MediaSeekRequest? {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let request = seekTrack?.request(at: seconds) else { return nil }
        enabled = false
        return request
    }
    func resolve(_ command: PlaybackCommand?) -> PlaybackCommand? {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return nil }
        enabled = false // Reserve one dispatch until the model reports completion.
        return command ?? (playing ? .pause : .play)
    }
}

@MainActor
final class SystemMediaController {
    private let center = MPNowPlayingInfoCenter.default()
    private let commands = MPRemoteCommandCenter.shared()
    private let gate = MediaCommandGate()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var last: MediaPresentation?
    private var active = false
    private let supportsSeek: Bool

    init(seek: (@MainActor (MediaSeekRequest) -> Void)? = nil, send: @escaping @MainActor (PlaybackCommand) -> Void) {
        supportsSeek = seek != nil
        for (remote, action) in [
            (commands.playCommand, PlaybackCommand.play as PlaybackCommand?),
            (commands.pauseCommand, PlaybackCommand.pause as PlaybackCommand?),
            (commands.togglePlayPauseCommand, nil),
            (commands.previousTrackCommand, PlaybackCommand.previous as PlaybackCommand?),
            (commands.nextTrackCommand, PlaybackCommand.next as PlaybackCommand?)
        ] {
            let gate = self.gate
            remote.isEnabled = false
            let token = remote.addTarget { _ in
                guard let command = gate.resolve(action) else { return .noActionableNowPlayingItem }
                DispatchQueue.main.async { send(command) }
                return .success // Accepted for dispatch, not a phone-side confirmation.
            }
            targets.append((remote, token))
        }
        let position = commands.changePlaybackPositionCommand
        position.isEnabled = false
        if let seek {
            let gate = self.gate
            let token = position.addTarget { event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent,
                      let request = gate.resolveSeek(event.positionTime) else { return .noActionableNowPlayingItem }
                DispatchQueue.main.async { seek(request) }
                return .success // Accepted for dispatch; the phone still confirms the seek.
            }
            targets.append((position, token))
        }
        commands.seekForwardCommand.isEnabled = false
        commands.seekBackwardCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.skipBackwardCommand.isEnabled = false
        commands.stopCommand.isEnabled = false
    }

    func update(_ state: Snapshot, busy: Bool, artwork: NSImage?, force: Bool = false, canSeek: Bool = false) {
        let labels = DisplayMetadata(state, correctLyricTitles: UserDefaults.standard.bool(forKey: "uiCorrectLyricTitles"))
        guard let presentation = MediaPresentation(state, previouslyActive: active, metadata: labels) else {
            clear(); return
        }
        let enabled = state.controlsAvailable && !busy
        let seekTrack = supportsSeek && canSeek ? MediaSeekTrack(state) : nil
        gate.update(enabled: enabled, playing: state.phase == .playing, seekTrack: seekTrack)
        for (command, _) in targets {
            command.isEnabled = enabled && (command !== commands.changePlaybackPositionCommand || seekTrack != nil)
        }
        guard force || last != presentation else { return }
        var info = presentation.info
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        center.nowPlayingInfo = info
        center.playbackState = presentation.playing ? .playing : .paused
        last = presentation; active = true
    }
    func clear() {
        gate.update(enabled: false, playing: false)
        for (command, _) in targets { command.isEnabled = false }
        if active {
            center.playbackState = .stopped
            center.nowPlayingInfo = nil
        }
        active = false; last = nil
    }
    func shutdown() {
        clear()
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
    }
}
