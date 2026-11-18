import AppKit
import SwiftUI

@MainActor private final class PagerFixture: ObservableObject {
    @Published var page = CompactPlayerPage.playback
    var playbackAppeared = 0
    var lyricsAppeared = 0
}

private struct PagerFixtureView: View {
    @ObservedObject var fixture: PagerFixture
    var body: some View {
        PlayerNarrowPager(selection: $fixture.page, requestPage: { fixture.page = $0 }) {
            VStack {
                Image(systemName: "music.note").font(.system(size: 64))
                Text("Playback page").font(.title2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.indigo.opacity(0.7))
                .onAppear { fixture.playbackAppeared += 1 }
        } lyrics: {
            VStack {
                Image(systemName: "quote.bubble").font(.system(size: 40))
                Text("Lyrics page\n歌词页面").font(.title2)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.teal.opacity(0.7))
                .onAppear { fixture.lyricsAppeared += 1 }
        }
    }
}

@main struct PlayerPresentationUISmoke {
    @MainActor static func main() throws {
        precondition(Bundle.main.bundleIdentifier == "tech.zrim.fusionplay.presentation-check")
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let typography = AppTypography()
        let titles = [("en", "A long song title that can use several readable lines without truncating every phrase",
                       "A long artist name and an equally long album title for the metadata preview"),
                      ("zh", "这是一个比较长的歌曲名称，用来检查窄窗中的换行和信息高度过渡",
                       "这是比较长的艺人名称 · 这也是比较长的专辑名称")]
        var count = 0
        func save<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String) throws {
            let host = NSHostingView(rootView: view.appTypography().padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(.white).background(Color.black).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            window.alphaValue = 0; window.orderBack(nil)
            host.layoutSubtreeIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
            window.contentView = nil; window.close(); count += 1
        }
        for (language, title, subtitle) in titles {
            for width in [260.0, 420.0] {
                for wraps in [false, true] {
                    UserDefaults.standard.setVolatileDomain(["wrapPlayerMetadata": wraps], forName: UserDefaults.argumentDomain)
                    let height = PlayerTrackMetadataView.height(title: title, subtitle: subtitle, width: width - 32,
                        titleFont: typography.nsFont(size: 19, weight: .semibold), subtitleFont: typography.nsFont(size: 12),
                        spacing: 5, wraps: wraps, defaultTitleLines: 2)
                    precondition(height > 0 && height < 180, "Metadata consumed the entire minimum-size player")
                    try save(PlayerTrackMetadataView(title: title, subtitle: subtitle, width: width - 32,
                        titleSize: 19, subtitleSize: 12, spacing: 5, defaultTitleLines: 2),
                        width: width, height: 200, name: "metadata-\(language)-\(Int(width))-\(wraps ? "wrap" : "plain")")
                }
            }
        }
        let fixture = PagerFixture()
        let host = NSHostingView(rootView: PagerFixtureView(fixture: fixture).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.alphaValue = 0; window.orderBack(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        precondition(fixture.playbackAppeared == 1 && fixture.lyricsAppeared == 1)
        for page in [CompactPlayerPage.playback, .lyrics, .playback] {
            fixture.page = page
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            host.layoutSubtreeIfNeeded()
            precondition(fixture.playbackAppeared == 1 && fixture.lyricsAppeared == 1,
                         "Page navigation recreated an existing lyric or playback subtree")
            precondition(host.bounds.size == NSSize(width: 320, height: 300))
            guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No pager bitmap") }
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("pager-" + page.rawValue + ".png"))
        }
        window.contentView = nil; window.close()
        print("PASS: \(count) actual metadata snapshots and mounted pager identity/navigation checks; no receiver or real preferences")
    }
}
