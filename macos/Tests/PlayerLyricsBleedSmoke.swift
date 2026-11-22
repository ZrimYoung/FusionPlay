import AppKit
import CoreImage
import SwiftUI

@MainActor private final class BleedInputCounter: NSObject {
    var clicks = 0
    @objc func clicked(_ sender: Any?) { clicks += 1 }
}
private struct BleedNativeButton: NSViewRepresentable {
    let counter: BleedInputCounter
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Play", target: counter, action: #selector(BleedInputCounter.clicked(_:)))
        button.identifier = .init("lyrics-bleed.neighbour-button")
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) {}
}

private struct BleedFixture: View {
    let target: PlayerCanvasPose
    let motion: PlayerResponsiveMotionDriver
    let viewport: CGSize
    let counter: BleedInputCounter
    private static let softInk: CGImage = {
        let context = CGContext(data: nil, width: 108, height: 128, bitsPerComponent: 8, bytesPerRow: 432,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 24, y: 24, width: 60, height: 80))
        let image = CIImage(cgImage: context.makeImage()!).applyingGaussianBlur(sigma: 12)
        return CIContext().createCGImage(image, from: CGRect(x: 0, y: 0, width: 108, height: 128))!
    }()
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            BleedNativeButton(counter: counter)
                .canvasPlacement(.playPause, target: target, motion: motion, interactive: true)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    // Own-view cacheDisplay omits compositor-only SwiftUI blur.
                    // Use known transparent soft ink to test only the role clip.
                    Image(decorative: Self.softInk, scale: 1).resizable()
                        .frame(width: 108, height: 128).offset(x: -24, y: -24)
                        .frame(width: 60, height: 80, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 600)
                }
                .padding(.horizontal, 27).padding(.top, 60)
            }
            .scrollClipDisabled().scrollIndicators(.hidden)
            .padding(.horizontal, -24)
            .canvasPlacement(.lyrics, target: target, motion: motion, interactive: true)
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        .padding(32)
        .background(Color(red: 0, green: 0.5, blue: 0))
    }
}

@main struct PlayerLyricsBleedSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        do { try check(); exit(0) }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor private static func check() throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "PlayerLyricsBleed", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        func pump(_ host: NSView) {
            let end = Date().addingTimeInterval(0.12)
            repeat { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.005)) } while Date() < end
        }
        let viewport = CGSize(width: 600, height: 380)
        var time: TimeInterval = 0
        let motion = PlayerResponsiveMotionDriver(automaticallyTicks: false, now: { time })
        let key = PlayerCanvasMotionKey(compact: false, cover: false, page: .playback,
            lyrics: true, controls: true, progress: true, transport: true)
        let counter = BleedInputCounter()
        let target = PlayerCanvasPose(nodes: [
            .lyrics: .init(frame: CGRect(x: 300, y: 40, width: 240, height: 300)),
            .playPause: .init(frame: CGRect(x: 220, y: 180, width: 52, height: 32))])
        motion.move(to: target, key: key, animated: false)
        let host = NSHostingView(rootView: BleedFixture(target: target, motion: motion, viewport: viewport, counter: counter))
        let window = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 664, height: 444),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
        defer { motion.stop(); window.contentView = nil; window.close() }
        pump(host)
        func pixels() throws -> (NSBitmapImageRep, [UInt8], Int, Int) {
            try require(!window.isVisible && !window.isKeyWindow && window.alphaValue == 0
                && NSApp.activationPolicy() == .prohibited, "Fixture ordered or activated a window")
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw NSError(domain: "Missing own-view bitmap", code: 1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let image = rep.cgImage else { throw NSError(domain: "Missing CGImage", code: 1) }
            let w = Int(host.bounds.width), h = Int(host.bounds.height)
            var data = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            return (rep, data, w, h)
        }
        func checkFrame(_ pose: PlayerCanvasPose, name: String, expectBleed: Bool) throws {
            pump(host)
            let (rep, data, width, _) = try pixels()
            let frame = pose[.lyrics].frame.offsetBy(dx: 32, dy: 32)
            let x = Int(frame.minX), y = Int(frame.minY + 100)
            let outside = Int(data[(y * width + x - 12) * 4])
            let inside = Int(data[(y * width + x + 30) * 4])
            if expectBleed && outside <= 8 {
                let samples = stride(from: -30, through: 36, by: 3).map { dx in "\(dx):\(data[(y * width + x + dx) * 4])" }
                print("PIXELS", samples)
                for scroll in descendants(host).compactMap({ $0 as? NSScrollView }) { print("SCROLL", scroll.convert(scroll.bounds, to: host)) }
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/player-lyrics-bleed-owned.png"))
            }
            if expectBleed {
                try require(outside > 8 && outside < inside && inside > 200,
                            "Horizontal blur was cut at the viewport: \(name), outside=\(outside), inside=\(inside)")
            }
            guard let probe = descendants(host).first(where: { $0.identifier?.rawValue == "fusionplay.player.hit-area.lyrics" }) else {
                throw NSError(domain: "No production role hit probe", code: 1)
            }
            try require(abs(probe.bounds.width - pose[.lyrics].frame.width) < 0.5
                && abs(probe.bounds.height - pose[.lyrics].frame.height) < 0.5,
                "Horizontal drawing room expanded the hit-role bounds")
            // The outer player/page clip must stop ink before the green witness.
            for point in [CGPoint(x: 25, y: y), CGPoint(x: 638, y: y)] {
                let offset = (Int(point.y) * width + Int(point.x)) * 4
                try require(data[offset] < 5 && data[offset + 1] > 70,
                            "Blur escaped the player/page boundary")
            }
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView }).first,
                  let button = descendants(host).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == "lyrics-bleed.neighbour-button" }) else {
                throw NSError(domain: "Missing real native input controls", code: 1)
            }
            func rootHit(_ point: CGPoint) -> NSView? { host.hitTest(host.convert(point, to: host.superview)) }
            let insidePane = CGPoint(x: frame.minX + 60, y: frame.minY + 160)
            if insidePane.x < viewport.width + 32 {
                let insideHit = rootHit(insidePane)
                try require(insideHit === scroll || insideHit?.isDescendant(of: scroll) == true,
                            "Native scroll stopped receiving input inside the lyric role")
            }
            let outsideInk = CGPoint(x: frame.minX - 10, y: frame.minY + 160)
            let hit = rootHit(outsideInk)
            try require(hit !== scroll && hit?.isDescendant(of: scroll) != true,
                        "Visual blur bleed stole native input outside its role")
            if pose[.playPause].frame.minX >= 0 {
                let buttonPoint = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
                let buttonHit = rootHit(buttonPoint)
                try require(buttonHit === button || buttonHit?.isDescendant(of: button) == true,
                            "Lyrics bleed covered its neighbouring native button")
                let clicks = counter.clicks
                button.performClick(nil)
                try require(counter.clicks == clicks + 1, "Neighbouring native button lost its action")
            }
            print("PASS \(name): outside=\(outside), inside=\(inside), role=\(probe.bounds.size), native hit/action retained")
        }
        try checkFrame(target, name: "wide", expectBleed: true)
        let page = PlayerCanvasPose(nodes: [
            .lyrics: .init(frame: CGRect(x: 8, y: 40, width: 240, height: 300)),
            .playPause: .init(frame: CGRect(x: -72, y: 180, width: 52, height: 32))])
        let pageKey = PlayerCanvasMotionKey(compact: true, cover: true, page: .lyrics,
            lyrics: true, controls: true, progress: true, transport: true)
        host.rootView = BleedFixture(target: page, motion: motion, viewport: viewport, counter: counter)
        motion.move(to: page, key: pageKey, animated: true)
        time = 0.12; motion.advance(to: time)
        try checkFrame(motion.pose!, name: "page-in-flight", expectBleed: true)
        time = 2; motion.advance(to: time)
        try checkFrame(page, name: "page-left-edge", expectBleed: false)
        let right = PlayerCanvasPose(nodes: [
            .lyrics: .init(frame: CGRect(x: 592, y: 40, width: 240, height: 300)),
            .playPause: .init(frame: CGRect(x: 512, y: 180, width: 52, height: 32))])
        host.rootView = BleedFixture(target: right, motion: motion, viewport: viewport, counter: counter)
        motion.move(to: right, key: pageKey, animated: false)
        try checkFrame(right, name: "page-right-edge", expectBleed: false)
        try require(NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "Fixture took foreground")
        print("PASS: native own-view bitmap blur extends horizontally, role hit bounds unchanged, page clips retained; no window ordering/activation/system input/screen capture")
    }
}
