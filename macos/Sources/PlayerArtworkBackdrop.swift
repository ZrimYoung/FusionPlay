import AppKit
import CoreImage
import SwiftUI

/// Prepared artwork pixels are shared by every background layer. Window resizing
/// only resizes the native layer; it never changes the image preparation request.
struct CachedArtworkBlur: NSViewRepresentable {
    enum Kind: Hashable {
        case ambient
        case cover(step: Int)
    }

    let artwork: NSImage
    let kind: Kind
    let loading: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ArtworkBlurView { ArtworkBlurView() }
    func updateNSView(_ view: ArtworkBlurView, context: Context) {
        view.configure(artwork: artwork, kind: kind, loading: loading, animated: !reduceMotion)
    }
    static func dismantleNSView(_ view: ArtworkBlurView, coordinator: ()) { view.disconnect() }

    final class ArtworkBlurView: NSView {
        private let owner = UUID()
        private var generation: UInt64 = 0
        private var source: ObjectIdentifier?
        private var kind: Kind?
        private var loading = false
        private var animated = true
        private var pendingImage: CGImage?
        private var displayedImage: CGImage?
#if FUSIONPLAY_UI_CHECKS
        private(set) var fadeRequestsForCheck = 0
        private(set) var fadeDurationForCheck: TimeInterval = 0
#endif

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.contentsGravity = .resizeAspectFill
            layer?.masksToBounds = true
            setAccessibilityElement(false)
        }
        convenience init() { self.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(artwork: NSImage, kind: Kind, loading: Bool, animated: Bool) {
            self.loading = loading; self.animated = animated
            if !animated { layer?.removeAnimation(forKey: "artwork") }
            let identity = ObjectIdentifier(artwork)
            guard source != identity || self.kind != kind else { displayPreparedImage(); return }
            generation &+= 1
            let request = generation
            source = identity; self.kind = kind; pendingImage = nil
            PlayerArtworkBlurProvider.shared.observe(owner: owner, artwork: artwork) { [weak self] prepared in
                guard let self, self.generation == request, self.source == identity else { return }
                self.pendingImage = prepared.image(for: kind)
                self.displayPreparedImage()
            }
        }

        private func displayPreparedImage() {
            guard let layer, let image = pendingImage else { return }
            // Keep the previous artwork throughout a loading interval. A first
            // image may be shown immediately rather than introducing a placeholder.
            guard !loading || displayedImage == nil else { return }
            if displayedImage === image { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if animated && displayedImage != nil {
                let transition = CATransition()
                transition.type = .fade; transition.duration = 0.60
                transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(transition, forKey: "artwork")
#if FUSIONPLAY_UI_CHECKS
                fadeRequestsForCheck += 1; fadeDurationForCheck = transition.duration
#endif
            }
            layer.contents = image; displayedImage = image
            CATransaction.commit()
        }

        func disconnect() {
            generation &+= 1; source = nil; kind = nil; pendingImage = nil
            PlayerArtworkBlurProvider.shared.remove(owner: owner)
        }
#if FUSIONPLAY_UI_CHECKS
        var preparedImageForCheck: CGImage? { displayedImage }
#endif
    }
}

private final class PreparedArtworkBlur: @unchecked Sendable {
    let ambient: CGImage
    let cover: [CGImage]
    init(ambient: CGImage, cover: [CGImage]) { self.ambient = ambient; self.cover = cover }
    func image(for kind: CachedArtworkBlur.Kind) -> CGImage {
        switch kind {
        case .ambient: return ambient
        case .cover(let step): return cover[min(3, max(0, step))]
        }
    }
}

@MainActor private final class PlayerArtworkBlurProvider {
    static let shared = PlayerArtworkBlurProvider()
    private final class Entry {
        let source: NSImage
        let generation: UInt64
        var observers: [UUID: (PreparedArtworkBlur) -> Void] = [:]
        var task: Task<PreparedArtworkBlur?, Never>?
        var prepared: PreparedArtworkBlur?
        init(source: NSImage, generation: UInt64) { self.source = source; self.generation = generation }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var owners: [UUID: ObjectIdentifier] = [:]
    private var cacheOrder: [ObjectIdentifier] = []
    private var generation: UInt64 = 0
    private(set) var tasksStarted = 0
    private(set) var tasksCompleted = 0
    private(set) var tasksCancelled = 0

    func observe(owner: UUID, artwork: NSImage, receive: @escaping (PreparedArtworkBlur) -> Void) {
        let identity = ObjectIdentifier(artwork)
        if owners[owner] != identity { remove(owner: owner) }
        owners[owner] = identity
        let entry: Entry
        if let cached = entries[identity] { entry = cached }
        else {
            generation &+= 1
            entry = Entry(source: artwork, generation: generation)
            entries[identity] = entry; cacheOrder.append(identity)
        }
        entry.observers[owner] = receive
        if let prepared = entry.prepared { receive(prepared); return }
        guard entry.task == nil else { return }
        // NSImage representation selection stays on the main actor. Core Image
        // receives immutable pixels and performs all filtering on a utility task.
        var proposed = NSRect(origin: .zero, size: artwork.size)
        guard let original = artwork.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return }
        let request = entry.generation
        let task = Task.detached(priority: .utility) { Self.prepare(original) }
        entry.task = task; tasksStarted += 1
        Task { [weak self] in
            let prepared = await task.value
            guard let self, let current = self.entries[identity], current.generation == request else { return }
            current.task = nil
            guard let prepared, !task.isCancelled else { return }
            current.prepared = prepared; self.tasksCompleted += 1
            for receive in Array(current.observers.values) { receive(prepared) }
            self.trimCache()
        }
    }

    func remove(owner: UUID) {
        guard let identity = owners.removeValue(forKey: owner), let entry = entries[identity] else { return }
        entry.observers.removeValue(forKey: owner)
        if entry.observers.isEmpty, let task = entry.task {
            task.cancel(); tasksCancelled += 1
            entries.removeValue(forKey: identity); cacheOrder.removeAll { $0 == identity }
        }
        trimCache()
    }

    private func trimCache() {
        // Keep at most three inactive images. Active surfaces may share an entry
        // without competing for it; identity is protected by the retained source.
        var inactive = cacheOrder.filter { entries[$0]?.observers.isEmpty == true }
        while inactive.count > 3 {
            let oldest = inactive.removeFirst()
            entries.removeValue(forKey: oldest); cacheOrder.removeAll { $0 == oldest }
        }
    }

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])
    nonisolated private static func prepare(_ image: CGImage) -> PreparedArtworkBlur? {
        func thumbnail(maximumSide: CGFloat) -> CIImage {
            let scale = min(1, maximumSide / CGFloat(max(image.width, image.height)))
            return CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard !Task.isCancelled else { return nil }
        let ambient = thumbnail(maximumSide: 112)
        guard let preparedAmbient = context.createCGImage(
            ambient.clampedToExtent().applyingGaussianBlur(sigma: 7), from: ambient.extent.integral) else { return nil }
        let cover = thumbnail(maximumSide: 512)
        // Aspect-fill into the square cover scales from the shorter image
        // dimension. Preserve the reference radii for non-square artwork too.
        let scale = min(cover.extent.width, cover.extent.height) / 420
        var preparedCover: [CGImage] = []
        for radius: CGFloat in [6, 14, 26, 40] {
            guard !Task.isCancelled,
                  let blurred = context.createCGImage(cover.clampedToExtent().applyingGaussianBlur(sigma: radius * scale),
                                                       from: cover.extent.integral) else { return nil }
            preparedCover.append(blurred)
        }
        guard !Task.isCancelled else { return nil }
        return PreparedArtworkBlur(ambient: preparedAmbient, cover: preparedCover)
    }
}

#if FUSIONPLAY_UI_CHECKS
@MainActor enum PlayerArtworkBlurCheck {
    static var tasksStarted: Int { PlayerArtworkBlurProvider.shared.tasksStarted }
    static var tasksCompleted: Int { PlayerArtworkBlurProvider.shared.tasksCompleted }
    static var tasksCancelled: Int { PlayerArtworkBlurProvider.shared.tasksCancelled }
}
#endif
