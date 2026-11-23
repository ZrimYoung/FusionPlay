import AppKit
import SwiftUI

@main struct PlayerMetadataWrappingSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited); app.finishLaunching()
        Task { @MainActor in
            do { try await check(); exit(0) }
            catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor static func check() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "tech.zrim.fusionplay.metadata-wrap-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let typography = AppTypography()
        var records: [[String: Any]] = []
        func pause() async { try? await Task.sleep(nanoseconds: 120_000_000) }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MetadataWrapping", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let cases = [("last-friday", "Last Friday Night (T.G.I.F.)", "", 140.0, 3, 2),
                     ("title-cjk", "这是比较长的歌曲名称用于检查换行行为", "", 180.0, 3, 2),
                     ("title-budget", "A long song title that must obey a two line budget", "", 160.0, 2, 2),
                     ("metadata", "Last Friday Night (T.G.I.F.)", "Katy Perry - Teenage Dream: The Complete Confection", 140.0, 3, 2),
                     ("budget", "A long song title with a strict title budget", "A long artist name - An equally long album name", 140.0, 1, 1)]
        for (name, title, subtitle, width, titleBudget, subtitleBudget) in cases {
            defaults.set(false, forKey: "wrapPlayerMetadata")
            let view = PlayerTrackMetadataView(title: title, subtitle: subtitle, width: width,
                titleSize: 22, subtitleSize: 13, spacing: 5, defaultTitleLines: 2,
                wrappedTitleLines: titleBudget, wrappedSubtitleLines: subtitleBudget, allowsSelection: true)
                .environment(\.appTypography, typography)
                .environment(\.colorScheme, .dark)
                .defaultAppStorage(defaults)
                .foregroundStyle(.white).background(Color.black)
                .fixedSize(horizontal: false, vertical: true)
                .transaction { $0.animation = nil; $0.disablesAnimations = true }
            let host = NSHostingView(rootView: view)
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = host
            window.orderBack(nil)
            var heights: [CGFloat] = [], titleBands: [Int] = []
            for (index, wraps) in [false, true, false].enumerated() {
                defaults.set(wraps, forKey: "wrapPlayerMetadata")
                await pause(); host.layoutSubtreeIfNeeded()
                let actual = host.fittingSize.height
                let expected = PlayerTrackMetadataView.height(title: title, subtitle: subtitle, width: width,
                    titleFont: typography.nsFont(size: 22, weight: .semibold), subtitleFont: typography.nsFont(size: 13),
                    spacing: 5, wraps: wraps, defaultTitleLines: 2,
                    wrappedTitleLines: titleBudget, wrappedSubtitleLines: subtitleBudget)
                try require(abs(actual - expected) <= 1.5,
                            "\(name) render height \(actual) differs from measurement \(expected) with wraps=\(wraps)")
                window.setContentSize(NSSize(width: width, height: actual)); await pause(); host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw NSError(domain: "MetadataBitmap", code: 1)
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let path = output.appendingPathComponent("\(name)-\(index)-\(wraps ? "on" : "off").png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: path)
                var record: [String: Any] = ["name": name, "wraps": wraps, "actualHeight": actual,
                    "measuredHeight": expected, "titleBudget": titleBudget, "subtitleBudget": subtitleBudget]
                if subtitle.isEmpty {
                    let scale = Double(bitmap.pixelsHigh) / max(1, actual)
                    let minimumBlank = max(2, Int(2 * scale))
                    var bands = 0, blank = minimumBlank
                    for y in 0..<bitmap.pixelsHigh {
                        let ink = (0..<bitmap.pixelsWide).contains { x in
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                            return color.alphaComponent > 0.1 && max(color.redComponent, color.greenComponent, color.blueComponent) > 0.45
                        }
                        if ink { if blank >= minimumBlank { bands += 1 }; blank = 0 }
                        else { blank += 1 }
                    }
                    record["renderedTitleLines"] = bands; titleBands.append(bands)
                    try require(wraps ? (bands > 1 && bands <= titleBudget) : bands == 1,
                                "\(name) rendered \(bands) title lines with wraps=\(wraps)")
                }
                heights.append(actual); records.append(record)
            }
            try require(abs(heights[0] - heights[2]) < 0.1, "Toggling off did not restore the original single-line height")
            if titleBudget > 1 {
                try require(heights[1] > heights[0] + 5, "Turning wrapping on failed to expand metadata")
            } else {
                try require(abs(heights[1] - heights[0]) < 0.1, "A one-line wrap budget was ignored")
            }
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "records": records], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("metadata-wrapping.json"))
        print("PASS: same native host OFF/ON/OFF, actual title bitmap line counts, single-line truncation, measured/rendered height parity, CJK and wrapped line budgets")
    }
}
