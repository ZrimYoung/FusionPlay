import CoreImage
import SwiftUI
import UIKit

struct PlayerArtworkBackdrop: View {
    let artwork: CGImage?
    let retainsWhileLoading: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var preparedArtwork: CGImage?

    private struct Request: Equatable {
        let artwork: ObjectIdentifier?
        let retainCurrent: Bool
    }

    var body: some View {
        let source = reduceTransparency ? nil : artwork
        let retainCurrent = !reduceTransparency && source == nil && retainsWhileLoading
        let request = Request(artwork: source.map(ObjectIdentifier.init), retainCurrent: retainCurrent)

        ArtworkBackdropLayer(
            artwork: reduceTransparency ? nil : preparedArtwork,
            animated: !reduceMotion && !reduceTransparency
        )
        .task(id: request) {
            guard let source else {
                if !retainCurrent { preparedArtwork = nil }
                return
            }
            let render = Task.detached(priority: .utility) { Self.makeBackdrop(from: source) }
            let image = await withTaskCancellationHandler {
                await render.value
            } onCancel: {
                render.cancel()
            }
            guard !Task.isCancelled else { return }
            preparedArtwork = image
        }
    }

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    nonisolated private static func makeBackdrop(from artwork: CGImage) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let side = CGFloat(max(artwork.width, artwork.height))
        let scale = min(1, 112 / side)
        let thumbnail = CIImage(cgImage: artwork)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = thumbnail.extent.integral
        let blurred = thumbnail.clampedToExtent().applyingGaussianBlur(sigma: 7)
        return context.createCGImage(blurred, from: bounds)
    }
}

private struct ArtworkBackdropLayer: UIViewRepresentable {
    let artwork: CGImage?
    let animated: Bool

    final class Coordinator {
        var artworkID: ObjectIdentifier?
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
        context.coordinator.artworkID = artworkID

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.60
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: "artwork")
        }
        layer.contents = artwork
        CATransaction.commit()
    }
}
