import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI

/// Filters the native Form's content before compositing. It draws no material,
/// tint or copied image, and the sidebar and toolbar remain outside the filter.
struct SettingsHeaderBackdrop: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
#if FUSIONPLAY_UI_CHECKS
    var checkReduceTransparency: Bool? = nil
    var checkReduceMotion: Bool? = nil
#endif
    private var resolvedReduceTransparency: Bool {
#if FUSIONPLAY_UI_CHECKS
        checkReduceTransparency ?? reduceTransparency
#else
        reduceTransparency
#endif
    }
    private var resolvedReduceMotion: Bool {
#if FUSIONPLAY_UI_CHECKS
        checkReduceMotion ?? reduceMotion
#else
        reduceMotion
#endif
    }
    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.update(reduceTransparency: resolvedReduceTransparency, reduceMotion: resolvedReduceMotion)
        return view
    }
    func updateNSView(_ view: BackdropView, context: Context) {
        view.update(reduceTransparency: resolvedReduceTransparency, reduceMotion: resolvedReduceMotion)
    }
    static func dismantleNSView(_ view: BackdropView, coordinator: ()) { view.stopObserving() }

    final class BackdropView: NSView {
        static let featherHeight: CGFloat = 56
        static let maximumRadius: CGFloat = 24
        let filterName = "fusionplaySettingsHeader_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        private let animationKey = "fusionplay.settings.header.radius"
        private var observers: [NSObjectProtocol] = []
        private var refreshRevision = 0
        private var reduceMotion = false
        private var reduceTransparency = false
        private(set) weak var trackedScrollView: NSScrollView?
        private(set) weak var filteredDocument: NSView?
        private(set) var scrollOffset: CGFloat = 0
        private(set) var revealProgress: CGFloat = 0
        private(set) var revealAnimationDuration: TimeInterval = 0
        private(set) var currentRadius: CGFloat = 0
        private(set) var bandInDocument: NSRect = .zero

        override var isFlipped: Bool { true }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            identifier = NSUserInterfaceItemIdentifier("fusionplay.settings.header.backdrop")
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopObserving() }
            else { scheduleObservation() }
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleObservation() }
        override func layout() { super.layout(); refreshObservation() }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize); scheduleObservation()
        }
        override func setBoundsSize(_ newSize: NSSize) {
            super.setBoundsSize(newSize); scheduleObservation()
        }
        func update(reduceTransparency: Bool, reduceMotion: Bool) {
            self.reduceTransparency = reduceTransparency
            self.reduceMotion = reduceMotion
            if reduceMotion { filteredDocument?.layer?.removeAnimation(forKey: animationKey) }
            updateScrollPosition()
            scheduleObservation()
        }
        private func scheduleObservation() {
            guard window != nil else { return }
            refreshRevision &+= 1
            let revision = refreshRevision
            // A replacement Form can attach its native scroll view one layout
            // later. Two bounded passes avoid polling the window.
            for delay in [0.0, 0.06] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.refreshRevision == revision, self.window != nil else { return }
                    self.refreshObservation()
                }
            }
        }
        func refreshObservation() {
            guard let root = window?.contentView, bounds.width > 0, bounds.height > 0 else { return }
            let scope = convert(bounds, to: nil)
            var candidates: [(NSScrollView, CGFloat)] = []
            func visit(_ view: NSView) {
                guard view !== self, !view.isHidden else { return }
                if let scroll = view as? NSScrollView, scroll.documentView != nil {
                    let overlap = scroll.convert(scroll.bounds, to: nil).intersection(scope)
                    if !overlap.isNull, overlap.width >= scope.width * 0.7, overlap.height > 40 {
                        candidates.append((scroll, overlap.width * overlap.height))
                    }
                }
                for child in view.subviews { visit(child) }
            }
            visit(root)
            let selected = candidates.max { $0.1 < $1.1 }?.0
            if trackedScrollView !== selected || filteredDocument !== selected?.documentView {
                stopObserving()
                trackedScrollView = selected
                filteredDocument = selected?.documentView
                if let selected {
                    selected.contentView.postsBoundsChangedNotifications = true
                    observers.append(NotificationCenter.default.addObserver(
                        forName: NSView.boundsDidChangeNotification, object: selected.contentView, queue: .main
                    ) { [weak self] _ in self?.updateScrollPosition() })
                    if let document = selected.documentView {
                        document.postsFrameChangedNotifications = true
                        observers.append(NotificationCenter.default.addObserver(
                            forName: NSView.frameDidChangeNotification, object: document, queue: .main
                        ) { [weak self] _ in self?.updateScrollPosition() })
                    }
                }
            }
            updateScrollPosition()
        }
        func stopObserving() {
            refreshRevision &+= 1
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            removeOwnFilter()
            trackedScrollView = nil; filteredDocument = nil
            scrollOffset = 0; revealProgress = 0
        }
        private func removeOwnFilter() {
            if let document = filteredDocument {
                document.layer?.removeAnimation(forKey: animationKey)
                let current = document.contentFilters
                let retained = current.filter { $0.name != filterName }
                if retained.count != current.count { document.contentFilters = retained }
            }
            currentRadius = 0; bandInDocument = .zero
        }
        private func updateScrollPosition() {
            guard let scroll = trackedScrollView, let document = filteredDocument else {
                removeOwnFilter(); scrollOffset = 0; revealProgress = 0; return
            }
            let clip = scroll.contentView
            let rect = clip.documentRect
            let offset = document.isFlipped ? clip.bounds.minY - rect.minY : rect.maxY - clip.bounds.maxY
            scrollOffset = offset.isFinite ? max(0, offset) : 0
            let phase = min(1, scrollOffset / 44)
            let target = reduceTransparency ? 0 : phase * phase * (3 - 2 * phase)
            let progressChanged = abs(target - revealProgress) > 0.0001
            revealProgress = target
            revealAnimationDuration = reduceMotion ? 0 : 0.18
            guard target > 0 else { removeOwnFilter(); return }
            let radius = Self.maximumRadius * target
            guard let effect = Self.makeFilter(document: document, clip: clip, radius: radius) else { removeOwnFilter(); return }
            effect.filter.name = filterName
            let keyPath = "filters." + filterName + ".inputRadius"
            let priorRadius = (document.layer?.presentation()?.value(forKeyPath: keyPath) as? NSNumber)?.doubleValue ?? Double(currentRadius)
            // Reattach a fresh filter: mutating an already attached CIFilter's
            // inputs has undefined Core Animation behavior.
            let others = document.contentFilters.filter { $0.name != filterName }
            document.contentFilters = others + [effect.filter]
            currentRadius = radius; bandInDocument = effect.band
            if progressChanged, !reduceMotion, abs(priorRadius - Double(radius)) > 0.01 {
                let animation = CABasicAnimation(keyPath: keyPath)
                animation.fromValue = priorRadius; animation.toValue = radius
                animation.duration = revealAnimationDuration
                animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                document.layer?.add(animation, forKey: animationKey)
            }
        }
        /// The native document can be flipped independently of its backing
        /// layer. Ask AppKit for the mapping rather than inferring it from the
        /// layer's isGeometryFlipped flag.
        static func makeFilter(document: NSView, clip: NSClipView, radius: CGFloat) -> (filter: CIFilter, band: NSRect)? {
            guard document.layer != nil, radius > 0, clip.bounds.height > 0 else { return nil }
            // Native Form bounds can extend under a transparent toolbar even
            // when SwiftUI clips its actual visible region below that toolbar.
            let visible = document.convert(clip.visibleRect, from: clip)
            guard visible.height > 0, visible.width > 0 else { return nil }
            let height = min(featherHeight, visible.height)
            let top = document.isFlipped ? visible.minY : visible.maxY
            let bottom = top + (document.isFlipped ? height : -height)
            let topPoint = document.convertToLayer(NSPoint(x: visible.midX, y: top))
            let bottomPoint = document.convertToLayer(NSPoint(x: visible.midX, y: bottom))
            let gradient = CIFilter.smoothLinearGradient()
            gradient.point0 = topPoint; gradient.point1 = bottomPoint
            gradient.color0 = .white; gradient.color1 = .black
            let filter = CIFilter.maskedVariableBlur()
            filter.radius = Float(radius)
            filter.mask = gradient.outputImage
            return (filter, NSRect(x: visible.minX, y: min(top, bottom), width: visible.width, height: height))
        }
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
