import SwiftUI

@MainActor
struct ReceiverProgressView: View {
    @ObservedObject var model: ReceiverModel
    private let prioritizesScrubbing: Bool
    @Environment(\.layoutDirection) private var layoutDirection
    @GestureState private var trackingDrag = false
    @State private var drag: Drag?

    init(model: ReceiverModel, prioritizesScrubbing: Bool = false) {
        self.model = model
        self.prioritizesScrubbing = prioritizesScrubbing
    }

    private enum Drag {
        case vertical
        case horizontal(TrackIdentity, Double)

        func fraction(for identity: TrackIdentity) -> Double? {
            guard case .horizontal(let captured, let fraction) = self,
                  captured == identity else { return nil }
            return fraction
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let identity = TrackIdentity(snapshot: model.snapshot)
            let duration = identity.duration ?? 0
            let current = model.displayedPositionMs
            let liveFraction = duration > 0 ? min(1, Double(current ?? 0) / Double(duration)) : 0
            let preview = drag?.fraction(for: identity)
            let displayedPosition = preview.map { Self.position(for: $0, duration: duration) } ?? current
            let hasSeekTarget = identity.connected && duration > 0 && current != nil
            let seekable = hasSeekTarget && model.canSeek

            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let track = progressTrack(width: width, fraction: preview ?? liveFraction)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("播放进度")
                        .accessibilityValue(Self.time(displayedPosition))

                    if hasSeekTarget {
                        let interaction = scrubGesture(width: width, identity: identity)
                            .exclusively(before: SpatialTapGesture().onEnded { event in
                                seek(to: fraction(at: event.location.x, width: width), for: identity)
                            })
                        interactiveTrack(track, gesture: interaction)
                            .allowsHitTesting(seekable)
                            .disabled(!seekable)
                            .accessibilityAdjustableAction { adjust($0, for: identity) }
                    } else {
                        track
                            .allowsHitTesting(false)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .frame(height: 44)

                HStack {
                    Text(Self.time(displayedPosition))
                    Spacer(minLength: 8)
                    Text(Self.time(identity.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.67))
                .accessibilityHidden(true)
            }
            .onChange(of: trackingDrag) { _, tracking in
                if !tracking { drag = nil }
            }
            .onDisappear { drag = nil }
        }
    }

    @ViewBuilder
    private func interactiveTrack<Track: View, Interaction: Gesture>(_ track: Track, gesture: Interaction) -> some View {
        if prioritizesScrubbing {
            track.highPriorityGesture(gesture)
        } else {
            track.simultaneousGesture(gesture)
        }
    }

    private func progressTrack(width: CGFloat, fraction: Double) -> some View {
        Capsule()
            .fill(.white.opacity(0.19))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(.tint)
                    .frame(width: width * fraction)
            }
            .frame(width: width, height: 4)
            .clipShape(Capsule())
    }

    private func scrubGesture(width: CGFloat, identity: TrackIdentity) -> some Gesture {
        DragGesture(minimumDistance: 7)
            .updating($trackingDrag) { _, tracking, _ in tracking = true }
            .onChanged { event in
                let value = fraction(at: event.location.x, width: width)
                switch drag {
                case .none:
                    let horizontal = abs(event.translation.width) > abs(event.translation.height)
                    drag = horizontal ? .horizontal(identity, value) : .vertical
                case .horizontal(let captured, _):
                    drag = .horizontal(captured, value)
                case .vertical:
                    break
                }
            }
            .onEnded { event in
                defer { drag = nil }
                guard case .horizontal(let captured, _) = drag else { return }
                seek(to: fraction(at: event.location.x, width: width), for: captured)
            }
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        let value = Double(min(1, max(0, x / width)))
        return layoutDirection == .rightToLeft ? 1 - value : value
    }

    private func seek(to fraction: Double, for identity: TrackIdentity) {
        guard let duration = seekableDuration(for: identity) else { return }
        model.seek(to: Self.position(for: fraction, duration: duration))
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection, for identity: TrackIdentity) {
        guard let duration = seekableDuration(for: identity), let current = model.displayedPositionMs else { return }
        let position = min(current, duration)
        switch direction {
        case .increment: model.seek(to: position + min(10_000, duration - position))
        case .decrement: model.seek(to: position - min(10_000, position))
        @unknown default: break
        }
    }

    private func seekableDuration(for identity: TrackIdentity) -> UInt64? {
        guard model.canSeek, TrackIdentity(snapshot: model.snapshot) == identity,
              let duration = identity.duration, duration > 0 else { return nil }
        return duration
    }

    private static func position(for fraction: Double, duration: UInt64) -> UInt64 {
        let target = (Double(duration) * min(1, max(0, fraction))).rounded(.down)
        return min(duration, UInt64(exactly: target) ?? duration)
    }

    private static func time(_ milliseconds: UInt64?) -> String {
        guard let milliseconds else { return "—" }
        let seconds = milliseconds / 1_000
        if seconds >= 3_600 {
            return String(format: "%llu:%02llu:%02llu", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%llu:%02llu", seconds / 60, seconds % 60)
    }
}
