import AppKit
import SwiftUI

@main struct CachedArtworkBlurSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited); app.finishLaunching(); app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }

    @MainActor private static func check() async throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "CachedArtworkBlur", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(30)
            while !predicate() {
                try require(Date() < deadline, "Prepared artwork timed out")
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let kinds: [CachedArtworkBlur.Kind] = [.ambient] + (0..<4).map { .cover(step: $0) }
        let views = kinds.map { _ in CachedArtworkBlur.ArtworkBlurView() }
        defer { views.forEach { $0.disconnect() } }
        let first = image(red: 1, green: 1, blue: 1)
        let started = PlayerArtworkBlurCheck.tasksStarted
        for (view, kind) in zip(views, kinds) { view.configure(artwork: first, kind: kind, loading: false, animated: true) }
        try await wait { views.allSatisfy { $0.preparedImageForCheck != nil } }
        try require(PlayerArtworkBlurCheck.tasksStarted == started + 1, "Five surfaces prepared duplicate artwork tasks")
        let initial = views.map { $0.preparedImageForCheck! }
        try require(max(initial[0].width, initial[0].height) <= 112, "Ambient image exceeds prepared size")
        try require(initial.dropFirst().allSatisfy { max($0.width, $0.height) <= 512 }, "Cover cache exceeds prepared size")
        let deviations = initial.dropFirst().map(deviation)
        try require(deviations.first! > deviations.last! + 5, "Cover blur radii lost their progressive strength")
        for tick in 0..<120 {
            for (view, kind) in zip(views, kinds) {
                view.setFrameSize(NSSize(width: 260 + tick * 7, height: 260 + tick * 3))
                view.configure(artwork: first, kind: kind, loading: false, animated: true)
                try require(view.hitTest(NSPoint(x: 10, y: 10)) == nil && !view.acceptsFirstResponder,
                            "Prepared background intercepted input")
            }
        }
        try require(PlayerArtworkBlurCheck.tasksStarted == started + 1, "Resizing repeated Core Image preparation")
        let second = image(red: 1, green: 0.15, blue: 0.05)
        let completed = PlayerArtworkBlurCheck.tasksCompleted
        for (view, kind) in zip(views, kinds) { view.configure(artwork: second, kind: kind, loading: true, animated: true) }
        try await wait { PlayerArtworkBlurCheck.tasksCompleted > completed }
        try require(zip(views, initial).allSatisfy { $0.preparedImageForCheck === $1 }, "Loading discarded the displayed cover")
        for (view, kind) in zip(views, kinds) { view.configure(artwork: second, kind: kind, loading: false, animated: true) }
        try require(zip(views, initial).allSatisfy { $0.preparedImageForCheck !== $1 }, "New prepared artwork did not replace old pixels")
        try require(views.allSatisfy { $0.fadeRequestsForCheck == 1 && $0.fadeDurationForCheck == 0.60 }, "Artwork replacement omitted the contents fade request")
        for (view, kind) in zip(views, kinds) { view.configure(artwork: second, kind: kind, loading: false, animated: false) }
        try require(views.allSatisfy { $0.layer?.animation(forKey: "artwork") == nil }, "Reduced motion retained an artwork animation")
        let obsolete = image(red: 0.1, green: 0.9, blue: 0.2)
        let latest = image(red: 0.1, green: 0.2, blue: 1)
        let cancelled = PlayerArtworkBlurCheck.tasksCancelled
        views[0].configure(artwork: obsolete, kind: .ambient, loading: false, animated: false)
        views[0].configure(artwork: latest, kind: .ambient, loading: false, animated: false)
        let previous = views[0].preparedImageForCheck
        try await wait { views[0].preparedImageForCheck !== previous }
        try require(PlayerArtworkBlurCheck.tasksCancelled > cancelled, "An obsolete unobserved generation kept running")
        let final = views[0].preparedImageForCheck!
        try await Task.sleep(for: .milliseconds(100))
        try require(views[0].preparedImageForCheck === final, "Obsolete completion overwrote the latest background")
        try require(views[0].fadeRequestsForCheck == 1, "Reduced motion requested another artwork fade")
        // The center crop of the wide checkerboard has the same physical pattern
        // as the square source. Equal point-radius blur must survive aspect-fill.
        let square = image(red: 1, green: 1, blue: 1, width: 512, height: 512)
        let wide = image(red: 1, green: 1, blue: 1, width: 1024, height: 512)
        let beforeSquare = views[0].preparedImageForCheck
        let beforeWide = views[1].preparedImageForCheck
        views[0].configure(artwork: square, kind: .cover(step: 0), loading: false, animated: false)
        views[1].configure(artwork: wide, kind: .cover(step: 0), loading: false, animated: false)
        try await wait { views[0].preparedImageForCheck !== beforeSquare && views[1].preparedImageForCheck !== beforeWide }
        let aspectFillError = aspectFillRMSE(views[0].preparedImageForCheck!, views[1].preparedImageForCheck!)
        try require(aspectFillError < 8, "Non-square aspect-fill changed the point blur radius: RMSE=\(aspectFillError)")
        try require(NSApp.windows.allSatisfy { !$0.isVisible } && NSApp.activationPolicy() == .prohibited
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid(), "Check displayed or activated a window")
        print("PASS: one shared preparation for five blur surfaces; ambient112/cover512; progressive radii \(deviations); 120 resizes without filtering; loading retention/fade request/reduced motion; generation cancellation; non-square aspectFill RMSE=\(aspectFillError); no windows/input/screenshots")
    }

    private static func image(red: CGFloat, green: CGFloat, blue: CGFloat, width: Int = 1024, height: Int = 1024) -> NSImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        for y in 0..<(height / 64) { for x in 0..<(width / 64) where (x + y).isMultiple(of: 2) {
            context.fill(CGRect(x: x * 64, y: y * 64, width: 64, height: 64))
        } }
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }

    private static func aspectFillRMSE(_ square: CGImage, _ wide: CGImage) -> Double {
        let side = 420
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: side * side * 4)
            data.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                let scale = max(CGFloat(side) / CGFloat(image.width), CGFloat(side) / CGFloat(image.height))
                let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
                context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2,
                    width: width, height: height))
            }
            return data
        }
        let a = pixels(square), b = pixels(wide)
        var squared = 0.0, count = 0.0
        // Exclude source-edge clamping; compare the actual shared center pattern.
        for y in stride(from: 64, to: side - 64, by: 2) {
            for x in stride(from: 64, to: side - 64, by: 2) {
                let offset = (y * side + x) * 4
                let delta = Double(a[offset]) - Double(b[offset])
                squared += delta * delta; count += 1
            }
        }
        return sqrt(squared / count)
    }

    private static func deviation(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        return data.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = raw.bindMemory(to: UInt8.self)
            var count = 0.0, sum = 0.0, squares = 0.0
            for y in stride(from: 0, to: height, by: 8) { for x in stride(from: 0, to: width, by: 8) {
                let value = Double(pixels[(y * width + x) * 4]); count += 1; sum += value; squares += value * value
            } }
            return sqrt(max(0, squares / count - pow(sum / count, 2)))
        }
    }
}
