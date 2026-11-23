import AppKit
import SwiftUI

/// Keeps a visible reading point stationary while native text changes height.
/// Compensation changes only the clip origin, never row sizing or view identity.
@MainActor final class LyricsViewportAnchor: ObservableObject {
    private final class WeakRow {
        weak var value: LyricsViewportRowView?
        init(_ value: LyricsViewportRowView) { self.value = value }
    }
    private struct ReadingPoint {
        let id: Int
        let rowFraction: CGFloat
        let viewportFraction: CGFloat
        let playingID: Int?
        let browsing: Bool
    }
    private var rows: [Int: WeakRow] = [:]
    private weak var scroll: NSScrollView?
    private var bindingOwner: ObjectIdentifier?
    private var observers: [NSObjectProtocol] = []
    private var readingObservers: [NSObjectProtocol] = []
    private var readingHierarchy: [ObjectIdentifier] = []
    private var readingPoint: ReadingPoint?
    private var captureWhenReady = false
    private var compensating = false
    private var activeID: Int?
    private var browsing = false
    private var enabled = true
    private(set) var lastGeometryChange = Date.distantPast
    var isHolding: Bool { readingPoint != nil }
#if FUSIONPLAY_UI_CHECKS
    var boundScrollForCheck: NSScrollView? { scroll }
    private(set) var bindingChangesForCheck = 0
    var heldReadingPoint: (id: Int, rowFraction: CGFloat, viewportFraction: CGFloat)? {
        readingPoint.map { ($0.id, $0.rowFraction, $0.viewportFraction) }
    }
#endif

    func configure(activeID: Int?, browsing: Bool, enabled: Bool, synchronousGeometry: Bool = false) {
        self.activeID = activeID
        self.browsing = browsing
        self.enabled = enabled
        if !enabled { cancel() }
        else if synchronousGeometry { beginIfNeeded(retryWhenReady: true) }
    }
    func attach(_ scroll: NSScrollView?, owner: AnyObject) {
        bindingOwner = ObjectIdentifier(owner)
        guard self.scroll !== scroll else { return }
        clearReadingObservers()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        self.scroll = scroll
#if FUSIONPLAY_UI_CHECKS
        bindingChangesForCheck += 1
#endif
        guard let scroll else { readingPoint = nil; return }
        for view in [scroll.contentView, scroll.documentView].compactMap({ $0 }) {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.compensating else { return }
                        self.scheduleCorrection()
                    }
                })
            }
        }
        if captureWhenReady { beginIfNeeded() }
        refreshReadingObservers()
    }
    func register(_ row: LyricsViewportRowView) {
        if rows[row.lineID]?.value === row {
            if captureWhenReady { beginIfNeeded() }
            if readingPoint?.id == row.lineID { refreshReadingObservers() }
            return
        }
        rows[row.lineID] = WeakRow(row)
        lastGeometryChange = Date()
        if captureWhenReady { beginIfNeeded() }
        if readingPoint?.id == row.lineID { refreshReadingObservers() }
        scheduleCorrection()
    }
    func unregister(_ row: LyricsViewportRowView) {
        if rows[row.lineID]?.value === row {
            rows.removeValue(forKey: row.lineID)
            if readingPoint?.id == row.lineID { clearReadingObservers() }
        }
    }
    func rowHierarchyChanged(_ row: LyricsViewportRowView) {
        guard readingPoint?.id == row.lineID, rows[row.lineID]?.value === row else { return }
        refreshReadingObservers()
        scheduleCorrection()
    }
    func rowChanged(_ row: LyricsViewportRowView) {
        lastGeometryChange = Date()
        if readingPoint?.id == row.lineID { refreshReadingObservers() }
        scheduleCorrection()
    }
    func beginIfNeeded(retryWhenReady: Bool = false) {
        guard enabled else { return }
        if retryWhenReady { captureWhenReady = true }
        guard readingPoint == nil, let scroll else { return }
        let clip = scroll.contentView
        guard clip.bounds.height > 0 else { return }
        let candidates = rows.values.compactMap(\.value).filter { $0.window === scroll.window }
        let visible = candidates.filter { row in
            let rect = row.convert(row.bounds, to: clip)
            return rect.intersects(clip.bounds)
        }
        let preferred = !browsing ? visible.first { $0.lineID == activeID } : nil
        let row = preferred ?? visible.min {
            abs(viewportTop($0, clip: clip) - clip.bounds.height * 0.32)
                < abs(viewportTop($1, clip: clip) - clip.bounds.height * 0.32)
        }
        guard let row, row.window === scroll.window else { return }
        let rect = row.convert(row.bounds, to: clip)
        let top = viewportTop(row, clip: clip)
        // Following preserves the first visible line. Browsing can preserve a
        // point inside a tall paragraph rather than pulling it back to its start.
        let fraction = browsing || top < 0
            ? min(1, max(0, (clip.bounds.height * 0.32 - top) / max(1, rect.height))) : 0
        let viewportY = top + rect.height * fraction
        readingPoint = ReadingPoint(id: row.lineID, rowFraction: fraction,
            viewportFraction: viewportY / clip.bounds.height, playingID: activeID, browsing: browsing)
        captureWhenReady = false
        lastGeometryChange = Date()
        refreshReadingObservers()
    }

    private func refreshReadingObservers() {
        guard let point = readingPoint, let scroll,
              let row = rows[point.id]?.value, row.window != nil, row.window === scroll.window else {
            clearReadingObservers(); return
        }
        var ancestors: [NSView] = []
        var node = row.superview
        while let view = node, view !== scroll.contentView {
            // Clip and document already have their own observation above.
            if view !== scroll.documentView { ancestors.append(view) }
            node = view.superview
        }
        guard node === scroll.contentView else { clearReadingObservers(); return }
        let hierarchy = ancestors.map(ObjectIdentifier.init)
        guard hierarchy != readingHierarchy else { return }
        clearReadingObservers()
        readingHierarchy = hierarchy
        // SwiftUI can move a placement ancestor after the document and the
        // row's local frame are already updated. Observe only this held row's
        // ordinary NSView chain so the final placement corrects in the same pass.
        for view in ancestors {
            view.postsFrameChangedNotifications = true
            view.postsBoundsChangedNotifications = true
            for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
                readingObservers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.compensating else { return }
                        self.lastGeometryChange = Date()
                        self.scheduleCorrection()
                    }
                })
            }
        }
    }
    private func clearReadingObservers() {
        readingObservers.forEach(NotificationCenter.default.removeObserver)
        readingObservers.removeAll(); readingHierarchy.removeAll()
    }
    private func viewportTop(_ row: NSView, clip: NSClipView) -> CGFloat {
        let rect = row.convert(row.bounds, to: clip)
        return clip.isFlipped ? rect.minY - clip.bounds.minY : clip.bounds.maxY - rect.maxY
    }
    private func scheduleCorrection() {
        guard readingPoint != nil else { return }
        // A held reading point must be corrected in the layout pass that moved
        // it, including the row-height animation after live resize ends. A queued
        // correction otherwise exposes one displaced frame before scrolling back.
        // correct() writes only clip origin, and its compensating guard ignores
        // the synchronous bounds notification caused by that write.
        correct()
    }

    func correct() {
        guard !compensating, let point = readingPoint, let scroll,
              let row = rows[point.id]?.value, row.window === scroll.window else { return }
        let clip = scroll.contentView
        let rect = row.convert(row.bounds, to: clip)
        let actual = viewportTop(row, clip: clip) + rect.height * point.rowFraction
        let desired = clip.bounds.height * point.viewportFraction
        let delta = actual - desired
        guard delta.isFinite, abs(delta) > 0.25 else { return }
        var bounds = clip.bounds
        bounds.origin.y += clip.isFlipped ? delta : -delta
        bounds = clip.constrainBoundsRect(bounds)
        guard abs(bounds.minY - clip.bounds.minY) > 0.25 else { return }
        compensating = true
        clip.scroll(to: bounds.origin)
        scroll.reflectScrolledClipView(clip)
        compensating = false
    }
    /// True means the same playing sentence was held; a final whole-page
    /// scroll would only undo that preservation and create a visible bounce.
    func finish(activeID: Int?) -> Bool {
        correct()
        let preserved = readingPoint.map { point in
            guard !point.browsing, point.id == activeID, point.playingID == activeID,
                  let scroll, let row = rows[point.id]?.value, row.window === scroll.window else { return false }
            return row.convert(row.bounds, to: scroll.contentView).intersects(scroll.contentView.bounds)
        } ?? false
        cancel()
        return preserved
    }
    func cancel() {
        readingPoint = nil; captureWhenReady = false
        clearReadingObservers()
    }
    func detach(owner: AnyObject) {
        guard bindingOwner == ObjectIdentifier(owner) else { return }
        disconnect()
    }
    func disconnect() {
        cancel(); observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll(); scroll = nil; bindingOwner = nil
    }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        readingObservers.forEach(NotificationCenter.default.removeObserver)
    }
}

struct LyricsViewportRowProbe: NSViewRepresentable {
    let id: Int
    let anchor: LyricsViewportAnchor
    func makeNSView(context: Context) -> LyricsViewportRowView {
        LyricsViewportRowView(lineID: id, anchor: anchor)
    }
    func updateNSView(_ view: LyricsViewportRowView, context: Context) {
        view.lineID = id
        view.anchor = anchor
        anchor.register(view)
    }
    static func dismantleNSView(_ view: LyricsViewportRowView, coordinator: ()) { view.anchor?.unregister(view) }
}

final class LyricsViewportRowView: NSView {
    var lineID: Int
    weak var anchor: LyricsViewportAnchor?
    init(lineID: Int, anchor: LyricsViewportAnchor) {
        self.lineID = lineID; self.anchor = anchor; super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview(); anchor?.rowHierarchyChanged(self)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { anchor?.register(self) }
        else { anchor?.rowHierarchyChanged(self) }
    }
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        let changed = frame.origin != newOrigin
        super.setFrameOrigin(newOrigin)
        if changed { anchor?.rowChanged(self) }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size != newSize
        super.setFrameSize(newSize)
        if changed { anchor?.rowChanged(self) }
    }
}
