import CoreImage
import SwiftUI
import UIKit

struct PlayerArtworkBackdrop: View {
    let artwork: CGImage?
    let retainsWhileLoading: Bool

    @AppStorage(ReceiverBackdropAppearance.blurKey) private var blurPercent = ReceiverBackdropAppearance.defaultBlurPercent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var preparedArtwork: PreparedArtwork?

    private struct PreparedArtwork {
        let source: CGImage
        let image: CGImage
    }

    private struct Request: Equatable {
        let source: ObjectIdentifier?
        let radius: Double
    }

    var body: some View {
        let prepared = reduceTransparency ? nil : preparedArtwork
        let source = reduceTransparency ? nil : artwork ?? (retainsWhileLoading ? prepared?.source : nil)
        let radius = ReceiverBackdropAppearance.blurRadius(percent: blurPercent)
        let request = Request(source: source.map(ObjectIdentifier.init), radius: radius)

        ArtworkBackdropLayer(
            artwork: prepared?.image,
            sourceID: prepared.map { ObjectIdentifier($0.source) },
            animated: !reduceMotion && !reduceTransparency
        )
        .task(id: request) {
            guard let source else {
                preparedArtwork = nil
                return
            }
            if prepared.map({ ObjectIdentifier($0.source) }) == request.source {
                // Coalesce slider updates for the current cover.
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
            let render = Task.detached(priority: .utility) { Self.makeBackdrop(from: source, radius: radius) }
            let image = await withTaskCancellationHandler {
                await render.value
            } onCancel: {
                render.cancel()
            }
            guard !Task.isCancelled, let image else { return }
            preparedArtwork = PreparedArtwork(source: source, image: image)
        }
    }

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    nonisolated private static func makeBackdrop(from artwork: CGImage, radius: Double) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        guard radius > 0 else { return artwork }
        let side = CGFloat(max(artwork.width, artwork.height))
        let baseSide: CGFloat = 112
        // Keep detail at low blur, with the same apparent radius at either resolution.
        let thumbnailSide = min(side, radius < 2 ? 320 : baseSide)
        let scale = thumbnailSide / side
        let radiusScale = max(baseSide, thumbnailSide) / baseSide
        let thumbnail = CIImage(cgImage: artwork)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = thumbnail.extent.integral
        let blurred = thumbnail.clampedToExtent().applyingGaussianBlur(sigma: radius * Double(radiusScale))
        return context.createCGImage(blurred, from: bounds)
    }
}

private struct ArtworkBackdropLayer: UIViewRepresentable {
    let artwork: CGImage?
    let sourceID: ObjectIdentifier?
    let animated: Bool

    final class Coordinator {
        var artworkID: ObjectIdentifier?
        var sourceID: ObjectIdentifier?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.layer.contentsGravity = .resizeAspectFill
        view.layer.masksToBounds = true
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let layer = view.layer
        if !animated { layer.removeAnimation(forKey: "artwork") }
        let artworkID = artwork.map(ObjectIdentifier.init)
        guard context.coordinator.artworkID != artworkID else { return }
        let sourceChanged = context.coordinator.sourceID != sourceID
        context.coordinator.artworkID = artworkID
        context.coordinator.sourceID = sourceID

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated && sourceChanged {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.60
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: "artwork")
        } else {
            layer.removeAnimation(forKey: "artwork")
        }
        layer.contents = artwork
        CATransaction.commit()
    }
}
