import AppKit
import SwiftUI

@MainActor private final class NativeMotionFixture: ObservableObject {
    @Published var width: CGFloat = 620
    @Published var reduced = false
    @Published var motionDelay: Double = 0
    @Published var font = NSFont.systemFont(ofSize: 34, weight: .bold)
    @Published var text = "Keep the quiet words together while the winding river moves across the mountains and the sea again"
}

private struct NativeMotionFixtureView: View {
    @ObservedObject var model: NativeMotionFixture
    var body: some View {
        LyricsReflowText(text: model.text, font: model.font, lineSpacing: 3,
                         reduceMotion: model.reduced, width: model.width, motionDelay: model.motionDelay)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@main struct NativeLyricsMotionSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("PASS: actual native glyph reflow, blur stages, row height, reverse resize, fonts, reduced motion and full 240/1000ms delays"); exit(0) }
            catch { FileHandle.standardError.write(Data("Native lyric motion check failed: \(error)\n".utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor private static func run() async throws {
        guard #available(macOS 15.0, *) else { print("SKIP: native TextRenderer requires macOS 15"); return }
        typealias Sample = NativeLyricsReflowCheckEvents.Sample
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func precondition(_ condition: @autoclosure () -> Bool, _ message: String = "Native motion assertion failed") {
            guard condition() else {
                FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1)
            }
        }
        let model = NativeMotionFixture()
        let plainFixtureText = model.text
        var phases: [Sample] = []
        var phaseTimes: [TimeInterval] = []
        NativeLyricsReflowCheckEvents.phase = {
            phases.append($0)
            phaseTimes.append(ProcessInfo.processInfo.systemUptime)
        }
        defer { NativeLyricsReflowCheckEvents.phase = nil; NativeLyricsReflowCheckEvents.sample = nil }
        let host = NSHostingView(rootView: NativeMotionFixtureView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 720, height: 800),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.alphaValue = 0; window.ignoresMouseEvents = true; window.orderBack(nil)
        defer { window.contentView = nil; window.close() }
        await pause(0.5)
        func current() -> Sample {
            guard let sample = NativeLyricsReflowCheckEvents.sample?() else { fatalError("No native renderer sample") }
            precondition(sample.renderer == "native-text-renderer" && sample.nativeLayoutCount > 0)
            precondition(sample.poses.values.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite && $0.opacity.isFinite })
            return sample
        }
        func save(_ sample: Sample, _ name: String) throws {
            let renderer = ImageRenderer(content: sample.preview.foregroundStyle(.white).background(.black))
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(width: sample.width, height: sample.height + 80)
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { fatalError("No native preview raster") }
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        }
        func resize(_ width: CGFloat) async {
            let count = current().nativeLayoutCount
            model.width = width
            for _ in 0..<100 {
                await pause(0.01)
                host.layoutSubtreeIfNeeded()
                if current().nativeLayoutCount > count { return }
            }
            fatalError("Width change never reached real Text.Layout")
        }
        let broad = current()
        precondition(broad.poses.count > 20)
        try save(broad, "native-wide")
        await resize(330)
        await pause(0.06)
        let fade = current()
        precondition(fade.movingClusterCount > 0 && fade.poses.values.contains { $0.moving && $0.blur > 0 })
        try save(fade, "native-narrow-vanish")
        await pause(0.16)
        let grow = current()
        precondition(grow.targetHeight > broad.height && grow.height > broad.height && grow.height < grow.targetHeight,
                     "Narrowing did not grow row height in its movement stage")
        precondition(grow.visibleMovingCount == 0, "Cross-line glyphs appeared while rows still moved")
        try save(grow, "native-narrow-space")
        await pause(0.16)
        let appear = current()
        precondition(abs(appear.height - appear.targetHeight) < 0.5)
        precondition(appear.poses.values.contains { $0.moving && $0.opacity > 0 && $0.opacity < 1 })
        try save(appear, "native-narrow-appear")
        await pause(0.25)
        let narrow = current()
        precondition(narrow.lineCount > broad.lineCount)
        await pause(0.12)
        precondition(current().nativeLayoutCount == narrow.nativeLayoutCount && abs(current().height - narrow.height) < 0.5,
                     "Settled native measurement restarted its own height animation")
        await resize(620)
        await pause(0.06)
        let vanish = current()
        precondition(abs(vanish.height - narrow.height) < 0.5, "Rows collapsed before the disappearing text")
        await pause(0.16)
        let collapse = current()
        precondition(collapse.visibleMovingCount == 0 && collapse.height < narrow.height && collapse.height > broad.height)
        try save(collapse, "native-wide-collapse")
        await pause(0.4)
        let wide = current()
        precondition(abs(wide.height - broad.height) < 0.5)
        // A modest width change leaves overlapping words on the same row;
        // the 620-to-330 fixture deliberately moves whole rows across lines.
        await resize(560); await pause(0.6)
        let middlePoses = current().poses
        await resize(620); await pause(0.6)
        let slideIDs = wide.poses.keys.filter { id in
            guard let a = wide.poses[id], let b = middlePoses[id] else { return false }
            return a.lineIndex == b.lineIndex && abs(a.origin.x - b.origin.x) > 5
        }
        precondition(!slideIDs.isEmpty, "Fixture must exercise same-line position changes")
        await resize(560); await pause(0.05)
        let sliding = current()
        precondition(slideIDs.contains { id in
            let a = wide.poses[id]!.origin.x, b = middlePoses[id]!.origin.x
            guard let x = sliding.poses[id]?.origin.x else { return false }
            return x > min(a, b) + 0.1 && x < max(a, b) - 0.1
        }, "Same-line glyphs jumped to their destination")
        let before = current()
        await resize(620)
        let reversed = current()
        for (id, pose) in before.poses where pose.opacity > 0.2 {
            guard let after = reversed.poses[id], after.opacity > 0.2 else { continue }
            precondition(hypot(after.origin.x - pose.origin.x, after.origin.y - pose.origin.y) < 36,
                         "Reverse resize jumped a visible glyph")
        }
        for width in [410.0, 560.0, 330.0, 620.0] { await resize(width); await pause(0.03) }
        await pause(0.75)
        precondition(current().poses.values.allSatisfy { $0.opacity == 1 && $0.blur == 0 })
        await resize(330); await pause(0.06)
        model.reduced = true
        await pause(0.08)
        let reduced = current()
        precondition(abs(reduced.height - reduced.targetHeight) < 0.5 && reduced.poses.values.allSatisfy { $0.opacity == 1 && $0.blur == 0 })
        model.font = NSFont(name: "HelveticaNeue-Bold", size: 34)!
        model.text = "office affine ffi \u{6e05}\u{6668}\u{7684}\u{5149}\u{1f3b5} \u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} \u{0645}\u{0648}\u{0633}\u{064a}\u{0642}\u{0649}"
        await pause(0.3)
        let custom = current()
        precondition(custom.fontName == model.font.fontName && custom.text == model.text && custom.poses.count > 10)
        try save(custom, "native-custom-unicode")

        // Keep native shaping intact while batching adjacent glyph draws:
        // this mixes Latin ligatures, CJK fallback, emoji and an Arabic run.
        model.reduced = false
        await resize(520); await pause(0.6)
        await resize(190); await pause(0.07)
        let unicodeFade = current()
        precondition(unicodeFade.text == model.text && unicodeFade.movingClusterCount > 0 &&
                     unicodeFade.poses.values.contains { $0.moving && $0.blur > 0 },
                     "Mixed-script native glyphs did not animate during reflow")
        try save(unicodeFade, "native-unicode-vanish")
        await pause(0.6)
        let unicodeNarrow = current()
        precondition(unicodeNarrow.poses.values.allSatisfy { $0.opacity == 1 && $0.blur == 0 })
        try save(unicodeNarrow, "native-unicode-narrow")
        let firstFontSizePhase = phases.count
        for size in [33.0, 29.0, 26.0, 31.0, 34.0] {
            model.font = NSFont(name: "HelveticaNeue-Bold", size: size)!
            await pause(0.04); host.layoutSubtreeIfNeeded()
            precondition(current().text == model.text)
        }
        await pause(0.7)
        precondition(!phases.dropFirst(firstFontSizePhase).contains { $0.phase == "reset" },
                     "Continuous point-size changes reset the native lyric identity")
        precondition(current().poses.values.allSatisfy { $0.opacity == 1 && $0.blur == 0 },
                     "Continuous font resizing retained stale glyph motion")

        // Exercise the full 240ms setting through the production wrapper. The
        // prior 140ms cap would already blur text at +180ms and move height by
        // +380ms, so these checks cannot pass with the old cap still present.
        model.motionDelay = 0.24
        model.font = NSFont.systemFont(ofSize: 34, weight: .bold)
        model.text = plainFixtureText
        await resize(620)
        await pause(0.12)
        model.reduced = false
        await pause(0.06)
        let delayedBroad = current()
        let firstDelayEvent = phases.count
        await resize(330)
        guard let delayBegin = phases.indices.dropFirst(firstDelayEvent).first(where: {
            phases[$0].phase == "begin" && phases[$0].direction == "expand" && abs(phases[$0].width - 330) < 0.5
        }) else { fatalError("240ms resize never began in native renderer") }
        let delayStarted = phaseTimes[delayBegin]
        func atDelayOffset(_ offset: Double) async -> Sample {
            await pause(max(0, delayStarted + offset - ProcessInfo.processInfo.systemUptime))
            host.layoutSubtreeIfNeeded()
            return current()
        }
        let waiting240 = await atDelayOffset(0.18)
        let earlyMoving = waiting240.poses.values.filter(\.moving)
        precondition(!earlyMoving.isEmpty && earlyMoving.allSatisfy { abs($0.opacity - 1) < 0.00001 && $0.blur < 0.00001 },
                     "240ms delay was truncated: cross-line glyphs changed before 180ms")
        for pose in earlyMoving {
            guard let prior = delayedBroad.poses[pose.id] else { continue }
            precondition(hypot(pose.origin.x - prior.origin.x, pose.origin.y - prior.origin.y) < 0.75,
                         "A delayed glyph moved before its 240ms start")
        }
        precondition(abs(waiting240.height - delayedBroad.height) < 0.5)
        let delayedFade = await atDelayOffset(0.34)
        precondition(delayedFade.poses.values.contains { $0.moving && $0.blur > 0.25 && $0.opacity < 1 },
                     "Native glyphs did not start blurring around delay + 100ms")
        precondition(abs(delayedFade.height - delayedBroad.height) < 0.5,
                     "Delayed height changed before glyph disappearance")
        let beforeDelayedHeight = await atDelayOffset(0.38)
        precondition(abs(beforeDelayedHeight.height - delayedBroad.height) < 0.5,
                     "Height used the old 140ms cap instead of the 240ms setting")
        let delayedGrowth = await atDelayOffset(0.46)
        precondition(delayedGrowth.height > delayedBroad.height + 0.5 && delayedGrowth.height < delayedGrowth.targetHeight - 0.5,
                     "240ms height did not move after delay + 34% of reflow duration")
        precondition(delayedGrowth.visibleMovingCount == 0,
                     "Delayed cross-line glyphs appeared while height was still moving")
        let delayedAppear = await atDelayOffset(0.62)
        precondition(abs(delayedAppear.height - delayedAppear.targetHeight) < 0.5)
        precondition(delayedAppear.poses.values.contains { $0.moving && $0.opacity > 0 && $0.opacity < 1 },
                     "240ms appearance stage ended early, as if capped at 140ms")
        let delayedSettled = await atDelayOffset(0.82)
        precondition(abs(delayedSettled.height - delayedSettled.targetHeight) < 0.5 &&
                     delayedSettled.poses.values.allSatisfy { $0.opacity == 1 && $0.blur == 0 },
                     "Nonzero-delay native motion did not settle")
        await pause(0.12)
        precondition(current().nativeLayoutCount == delayedSettled.nativeLayoutCount &&
                     abs(current().height - delayedSettled.height) < 0.5,
                     "240ms native motion restarted after settling")
        // Each preview captured its analytical time above. Rasterizing only
        // after the timing assertions avoids screenshot work skewing samples.
        try save(delayedFade, "native-240ms-vanish")
        try save(delayedGrowth, "native-240ms-height")
        try save(delayedAppear, "native-240ms-appear")

        // Verify the enlarged one-second limit through actual TextRenderer
        // motion; a surviving 240ms cap would be fully settled at +800ms.
        model.reduced = true
        await resize(620)
        await pause(0.12)
        model.motionDelay = 1
        model.reduced = false
        await pause(0.06)
        let secondBroad = current()
        let firstSecondEvent = phases.count
        await resize(330)
        guard let secondBegin = phases.indices.dropFirst(firstSecondEvent).first(where: {
            phases[$0].phase == "begin" && phases[$0].direction == "expand" && abs(phases[$0].width - 330) < 0.5
        }) else { fatalError("One-second resize never began in native renderer") }
        let secondStarted = phaseTimes[secondBegin]
        func atSecondOffset(_ offset: Double) async -> Sample {
            await pause(max(0, secondStarted + offset - ProcessInfo.processInfo.systemUptime))
            host.layoutSubtreeIfNeeded()
            return current()
        }
        let waitingSecond = await atSecondOffset(0.8)
        let secondMoving = waitingSecond.poses.values.filter(\.moving)
        precondition(!secondMoving.isEmpty && secondMoving.allSatisfy { abs($0.opacity - 1) < 0.00001 && $0.blur < 0.00001 },
                     "One-second delay was clamped: glyphs changed before 800ms")
        for pose in secondMoving {
            guard let prior = secondBroad.poses[pose.id] else { continue }
            precondition(hypot(pose.origin.x - prior.origin.x, pose.origin.y - prior.origin.y) < 0.75,
                         "One-second delayed glyph moved before its start")
        }
        precondition(abs(waitingSecond.height - secondBroad.height) < 0.5)
        let secondFade = await atSecondOffset(1.1)
        precondition(secondFade.poses.values.contains { $0.moving && $0.blur > 0.25 && $0.opacity < 1 },
                     "One-second delayed glyphs did not enter their native blur stage")
        precondition(abs(secondFade.height - secondBroad.height) < 0.5)
        let secondGrowth = await atSecondOffset(1.22)
        precondition(secondGrowth.height > secondBroad.height + 0.5 && secondGrowth.height < secondGrowth.targetHeight - 0.5,
                     "One-second delayed height did not retain the native .48-second choreography")
        precondition(secondGrowth.visibleMovingCount == 0)
        let secondAppear = await atSecondOffset(1.38)
        precondition(abs(secondAppear.height - secondAppear.targetHeight) < 0.5)
        precondition(secondAppear.poses.values.contains { $0.moving && $0.opacity > 0 && $0.opacity < 1 })
        let secondSettled = await atSecondOffset(1.55)
        precondition(abs(secondSettled.height - secondSettled.targetHeight) < 0.5 &&
                     secondSettled.poses.values.allSatisfy { $0.opacity == 1 && $0.blur == 0 },
                     "One-second delayed native motion did not settle after 1.5 seconds")
        await pause(0.12)
        precondition(current().nativeLayoutCount == secondSettled.nativeLayoutCount &&
                     abs(current().height - secondSettled.height) < 0.5)
        try save(secondFade, "native-1000ms-vanish")
        try save(secondGrowth, "native-1000ms-height")
        try save(secondAppear, "native-1000ms-appear")
        let records = phases.map { s in
            ["renderer": s.renderer, "direction": s.direction, "phase": s.phase, "revision": s.revision,
             "height": s.height, "targetHeight": s.targetHeight, "nativeLayouts": s.nativeLayoutCount,
             "movingClusters": s.movingClusterCount, "visibleMovingClusters": s.visibleMovingCount] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: ["passed": true, "phases": records,
            "verifiedNonzeroDelayMilliseconds": 240,
            "verifiedMaximumDelayMilliseconds": 1000,
            "visibleTestWindows": false, "receiverStarted": false, "realPreferencesChanged": false],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("native-motion-check.json"), options: .atomic)
    }
}
