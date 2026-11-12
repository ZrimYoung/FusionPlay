import AppKit
import SwiftUI

// A small, monochrome companion to the full-color interlocking-ring app icon.
struct DoubleRingMark: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / 24, rect.height / 18)
        let x = rect.midX - 12 * scale
        let y = rect.midY
        var path = Path()
        path.addArc(center: CGPoint(x: x + 8 * scale, y: y), radius: 6.5 * scale,
                    startAngle: .degrees(66), endAngle: .degrees(402), clockwise: false)
        path.move(to: CGPoint(x: x + (16 + 6.5 * cos(246 * .pi / 180)) * scale,
                             y: y + 6.5 * sin(246 * .pi / 180) * scale))
        path.addArc(center: CGPoint(x: x + 16 * scale, y: y), radius: 6.5 * scale,
                    startAngle: .degrees(246), endAngle: .degrees(582), clockwise: false)
        return path
    }
}

enum AppBrand {
    static let menuIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(DoubleRingMark().path(in: rect).cgPath)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(1.5)
            context.setLineCap(.butt)
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func dockImage(from artwork: NSImage) -> NSImage {
        // applicationIconImage is a complete Dock tile, not an asset-catalog
        // source. Give the opaque artwork the standard inset and rounded tile.
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { bounds in
            let tile = bounds.insetBy(dx: 100, dy: 100)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            artwork.draw(in: tile)
            return true
        }
    }

    static func applyDockIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url), icon.isValid else { return }
        // Set the running Dock tile explicitly, even when Launch Services has
        // cached the generic icon from an older in-place development build.
        NSApp.applicationIconImage = dockImage(from: icon)
        NSApp.dockTile.display()
    }
}

// Vector artwork for in-app presentation; independent of the Dock's raster asset.
struct AboutBrandIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.96)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                DoubleRingMark()
                    .stroke(LinearGradient(stops: [
                        .init(color: Color(red: 0.22, green: 0.55, blue: 1), location: 0),
                        .init(color: Color(red: 0.04, green: 0.32, blue: 1), location: 0.45),
                        .init(color: Color(red: 0.04, green: 0.22, blue: 0.9), location: 1)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                            style: StrokeStyle(lineWidth: side * 0.038, lineCap: .round))
                    .frame(width: side * 0.65, height: side * 0.49)
            }.frame(width: side, height: side)
        }
    }
}
