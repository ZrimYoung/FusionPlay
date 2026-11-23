import AppKit
import Combine
import SwiftUI

struct PlayerCanvasMotionKey: Equatable {
    let compact: Bool
    let cover: Bool
    let page: CompactPlayerPage
    let lyrics: Bool
    let controls: Bool
    let progress: Bool
    let transport: Bool
    var wraps = false
    var headerArtwork = false
    var headerInfo = false
}

/// Position and velocity are explicit model values, rather than compositor-only
/// geometry effects. A common-mode timer also advances during native resizing.
@MainActor final class PlayerResponsiveMotionDriver: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    private(set) var pose: PlayerCanvasPose?
    private(set) var isAnimating = false
    private(set) var isResizingLyrics = false
    private(set) var key: PlayerCanvasMotionKey?
    private let animationsEnabled: Bool
    private let automaticallyTicks: Bool
    private let now: () -> TimeInterval
    private var timer: Timer?
    private var origin: [Double] = []
    private var velocity: [Double] = []
    private var destination: [Double] = []
    private var started: TimeInterval = 0
    private var omega: Double = 16
    private var template: PlayerCanvasPose?
    var hasScheduledTimer: Bool { timer != nil }
#if FUSIONPLAY_UI_CHECKS
    var targetPoseForCheck: PlayerCanvasPose? { template }
#endif

    init(animationsEnabled: Bool = true, automaticallyTicks: Bool = true,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.animationsEnabled = animationsEnabled
        self.automaticallyTicks = automaticallyTicks
        self.now = now
    }

    func move(to target: PlayerCanvasPose, key nextKey: PlayerCanvasMotionKey, animated: Bool) {
        let time = now()
        let vector = target.motionVector
        let changedMode = key != nil && key != nextKey
        let shouldAnimate = animationsEnabled && animated && pose != nil && (changedMode || isAnimating)
        key = nextKey
        // Playback ticks must neither restart the spring nor publish extra frames.
        if template == target && destination == vector {
            if !animated || !animationsEnabled { settle(target, at: time) }
            return
        }
        guard shouldAnimate else { settle(target, at: time); return }
        let state = sampled(at: time)
        origin = state.position
        velocity = state.velocity
        destination = vector
        template = target
        started = time
        omega = changedMode ? 16 : omega
        isAnimating = true
        let lyricIndex = PlayerCanvasElement.allCases.firstIndex(of: .lyrics)! * 5
        isResizingLyrics = [lyricIndex + 2, lyricIndex + 3].contains {
            abs(origin[$0] - destination[$0]) > 0.25 || abs(velocity[$0]) > 0.25
        }
        publish(origin)
        if automaticallyTicks && timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.advance(to: self.now())
                }
            }
            timer.tolerance = 0.001
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func advance(to time: TimeInterval) {
        guard isAnimating, let template else { return }
        let state = sampled(at: time)
        let close = zip(state.position, destination).allSatisfy { abs($0 - $1) < 0.025 }
            && state.velocity.allSatisfy { abs($0) < 0.2 }
        if close || time - started > 1.5 {
            settle(template, at: time)
        } else { publish(state.position) }
    }

    func stop() {
        let wasAnimating = isAnimating
        timer?.invalidate(); timer = nil
        isAnimating = false; isResizingLyrics = false
        // A reopened view starts from its current geometry instead of replaying
        // a stale transition that began in another window size.
        pose = nil; template = nil; origin = []; velocity = []; destination = []; key = nil
        if wasAnimating { objectWillChange.send() }
    }

    private func settle(_ target: PlayerCanvasPose, at time: TimeInterval) {
        let wasAnimating = isAnimating
        timer?.invalidate(); timer = nil
        template = target; origin = target.motionVector; destination = origin
        velocity = Array(repeating: 0, count: origin.count); started = time
        isAnimating = false; isResizingLyrics = false
        // The parent already supplied the new target during normal resize.
        // Publishing it again inside onChange causes a second synchronous
        // layout pass for every placement, even when both flags stay false.
        publishPose(target, notifying: wasAnimating)
    }

    private func sampled(at time: TimeInterval) -> (position: [Double], velocity: [Double]) {
        guard origin.count == destination.count, !origin.isEmpty else {
            return (pose?.motionVector ?? [], velocity)
        }
        let t = max(0, time - started), decay = exp(-omega * t)
        var values: [Double] = [], speeds: [Double] = []
        values.reserveCapacity(origin.count); speeds.reserveCapacity(origin.count)
        for index in origin.indices {
            let offset = origin[index] - destination[index]
            let initialSpeed = velocity.indices.contains(index) ? velocity[index] : 0
            let c = initialSpeed + omega * offset
            values.append(destination[index] + (offset + c * t) * decay)
            speeds.append((initialSpeed - omega * c * t) * decay)
        }
        return (values, speeds)
    }

    private func publish(_ values: [Double]) {
        guard let template else { return }
        publishPose(template.replacingMotionVector(values))
    }
    private func publishPose(_ value: PlayerCanvasPose, notifying: Bool = true) {
        // Frames are already interpolated. An inherited implicit animation would
        // add a second lagging animation or be suppressed by AppKit live resize.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            pose = value
            if notifying { objectWillChange.send() }
        }
    }
    deinit { timer?.invalidate() }
}

extension PlayerCanvasPose {
    fileprivate var motionVector: [Double] {
        var result: [Double] = []
        for element in PlayerCanvasElement.allCases {
            let node = self[element]
            result += [Double(node.frame.minX), Double(node.frame.minY), Double(node.frame.width), Double(node.frame.height), node.opacity]
        }
        result += [Double(titleSize), Double(subtitleSize), Double(metadataSpacing), subtitleOpacity,
                   Double(artworkRadius), glassOpacity, Double(contentHeight), Double(controlsHeight)]
        return result
    }
    fileprivate func replacingMotionVector(_ values: [Double]) -> Self {
        guard values.count == PlayerCanvasElement.allCases.count * 5 + 8 else { return self }
        var result = self, cursor = 0
        for element in PlayerCanvasElement.allCases {
            result.nodes[element] = PlayerCanvasNode(
                frame: CGRect(x: values[cursor], y: values[cursor + 1], width: max(1, values[cursor + 2]), height: max(1, values[cursor + 3])),
                opacity: min(1, max(0, values[cursor + 4])))
            cursor += 5
        }
        result.titleSize = CGFloat(values[cursor]); result.subtitleSize = CGFloat(values[cursor + 1])
        result.metadataSpacing = CGFloat(values[cursor + 2]); result.subtitleOpacity = values[cursor + 3]
        result.artworkRadius = CGFloat(max(0, values[cursor + 4])); result.glassOpacity = min(1, max(0, values[cursor + 5]))
        result.contentHeight = CGFloat(max(1, values[cursor + 6])); result.controlsHeight = CGFloat(max(1, values[cursor + 7]))
        return result
    }
}

struct PlayerCanvasMotionInput: Equatable {
    let pose: PlayerCanvasPose
    let key: PlayerCanvasMotionKey
}

/// Observe motion only around the lightweight placement. Its content and
/// expensive native text proposals are built once per actual target change.
private struct PlayerCanvasPlacement: ViewModifier {
    let element: PlayerCanvasElement
    let target: PlayerCanvasPose
    @ObservedObject var motion: PlayerResponsiveMotionDriver
    let interactive: Bool

    func body(content: Content) -> some View {
        let pose = motion.isAnimating ? (motion.pose ?? target) : target
        let node = pose[element]
        roleContent(content, pose: pose)
            // Position takes the canvas proposal. Define the hit region first,
            // while the layout still has this role's own visible bounds.
            .contentShape(Rectangle())
#if FUSIONPLAY_UI_CHECKS
            .background { PlayerCanvasHitBoundsProbe(element: element).allowsHitTesting(false) }
#endif
            .position(x: node.frame.midX, y: node.frame.midY)
            .opacity(node.opacity)
            .allowsHitTesting(interactive && node.opacity > 0.05)
            .accessibilityHidden(!interactive || node.opacity < 0.05)
    }

    @ViewBuilder private func roleContent(_ content: Content, pose: PlayerCanvasPose) -> some View {
        let frame = pose[element].frame
        let base = target[element].frame
        switch element {
        case .lyrics:
            // LyricsView already reserves horizontal ink bleed without moving
            // its text. Clip the same extra drawing room here, then restore the
            // original role bounds before defining its hit area and placement.
            // The enclosing player/page clip still owns the outer boundary.
            content.frame(width: base.width, height: base.height, alignment: .topLeading)
                .geometryGroup()
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .padding(.horizontal, 24)
                .clipped()
                .padding(.horizontal, -24)
        case .lyricsHeader, .lyricSummary:
            content.frame(width: base.width, height: base.height, alignment: .topLeading)
                .geometryGroup()
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipped()
        case .metadata:
            let scale = max(0.01, pose.titleSize / max(1, target.titleSize))
            content.frame(width: base.width, height: base.height, alignment: .topLeading)
                .geometryGroup()
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .clipped()
        case .artwork:
            scaled(content, frame: frame, base: base)
                .clipShape(RoundedRectangle(cornerRadius: pose.artworkRadius))
                .overlay(RoundedRectangle(cornerRadius: pose.artworkRadius)
                    .strokeBorder(.white.opacity(0.1 * min(1, pose.artworkRadius / 12)), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.28 * min(1, pose.artworkRadius / 12)), radius: 20, y: 12)
        case .coverBackdrop:
            scaled(content, frame: frame, base: base).clipped()
        case .previous, .playPause, .next, .progress:
            // Small controls have no lyric/metadata typesetting. Keep their
            // live frame so text stays unstretched and hit areas follow them.
            content.frame(width: frame.width, height: frame.height, alignment: .topLeading)
        }
    }

    private func scaled(_ content: Content, frame: CGRect, base: CGRect) -> some View {
        content.frame(width: base.width, height: base.height, alignment: .topLeading).clipped()
            .geometryGroup()
            .scaleEffect(x: frame.width / max(1, base.width), y: frame.height / max(1, base.height), anchor: .topLeading)
            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    }
}


#if FUSIONPLAY_UI_CHECKS
/// A transparent, non-interactive native witness to the actual content-shape
/// proposal. It is absent from release builds and never participates in input.
private struct PlayerCanvasHitBoundsProbe: NSViewRepresentable {
    let element: PlayerCanvasElement
    func makeNSView(context: Context) -> NSView {
        let view = HitBoundsView()
        view.identifier = .init("fusionplay.player.hit-area." + element.rawValue)
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    final class HitBoundsView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif

struct PlayerCanvasGlassVisual<Content: View>: View {
    @ObservedObject var motion: PlayerResponsiveMotionDriver
    let targetOpacity: Double
    @ViewBuilder let content: (Double) -> Content
    var body: some View { content(motion.isAnimating ? (motion.pose?.glassOpacity ?? targetOpacity) : targetOpacity) }
}

extension View {
    func canvasPlacement(_ element: PlayerCanvasElement, target: PlayerCanvasPose,
                         motion: PlayerResponsiveMotionDriver, interactive: Bool) -> some View {
        modifier(PlayerCanvasPlacement(element: element, target: target, motion: motion, interactive: interactive))
    }
}
