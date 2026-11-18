import SwiftUI
import UIKit

struct CompactLyricsTrackHeader: View {
    let artwork: UIImage?
    let title: String
    let subtitle: String
    let showsArtwork: Bool
    let showsTrackInfo: Bool

    @Environment(\.receiverTypography) private var typography
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasTrackInfo: Bool { showsTrackInfo && (!title.isEmpty || !subtitle.isEmpty) }

    var body: some View {
        if showsArtwork || hasTrackInfo {
            HStack(spacing: 12) {
                if showsArtwork { cover }
                if hasTrackInfo { trackInfo }
            }
            .frame(maxWidth: .infinity, alignment: hasTrackInfo ? .leading : .center)
        }
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !title.isEmpty {
                Text(verbatim: title)
                    .font(typography.font(.headline, size: 17, weight: .semibold))
                    .accessibilityLabel(Text(verbatim: title))
                    .accessibilityAddTraits(.isHeader)
            }
            if !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(typography.font(.subheadline, size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .accessibilityLabel(Text(verbatim: subtitle))
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var cover: some View {
        let side: CGFloat = 56
        let shape = RoundedRectangle(cornerRadius: 10)
        return ZStack {
            shape.fill(Color(red: 0.09, green: 0.16, blue: 0.19).gradient)
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(artwork == nil ? 1 : 0)
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .id(ObjectIdentifier(artwork))
                    .transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay { shape.strokeBorder(.white.opacity(0.13)) }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: artwork.map(ObjectIdentifier.init))
        .accessibilityHidden(true)
    }
}
