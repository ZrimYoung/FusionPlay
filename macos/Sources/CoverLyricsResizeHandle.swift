import AppKit
import QuartzCore
import SwiftUI

/// Keeps the square cover and the stacked lyric pane in one native resize flow.
struct CoverLyricsResizeHandle: NSViewRepresentable {
    let expanded: Bool
    let onDraggingChanged: (Bool) -> Void
    let onExpansionChanged: (Bool) -> Void

    func makeNSView(context: Context) -> CoverLyricsResizeGrip {
        let view = CoverLyricsResizeGrip()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: CoverLyricsResizeGrip, context: Context) {
        view.expanded = expanded
        view.onDraggingChanged = onDraggingChanged
        view.onExpansionChanged = onExpansionChanged
    }
    static func dismantleNSView(_ view: CoverLyricsResizeGrip, coordinator: ()) { view.invalidate() }
}

final class CoverLyricsResizeGrip: NSView {
    private struct PointerResize {
        let point: NSPoint
        let frame: NSRect
        let content: NSSize
        var started = false
        var rejected = false
    }
    var expanded = false
    var onDraggingChanged: (Bool) -> Void = { _ in }
    var onExpansionChanged: (Bool) -> Void = { _ in }
    private var pointerResize: PointerResize?
    private var dragging = false
    private var settling = false
    private var generation: UInt64 = 0
    private var mouseMonitor: Any?
    private let indicator = CALayer()
    private var accessibilityObserver: NSObjectProtocol?
#if FUSIONPLAY_UI_CHECKS
    var testIndicatorReduceMotion: Bool?
#endif
    private var rememberedPaneHeight: CGFloat = 220
    private var hovering = false
    private var transition = false
    private var tracking: NSTrackingArea?
    private var observations: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    static let collapseThreshold: CGFloat = 72
    static let minimumExpandedHeight: CGFloat = 136

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        indicator.name = "fusionplay.cover-lyrics-grip-indicator"
        indicator.backgroundColor = NSColor.white.cgColor
        indicator.cornerRadius = 1.5
        indicator.opacity = 0
        layer?.addSublayer(indicator)
        identifier = NSUserInterfaceItemIdentifier("fusionplay.player.cover-lyrics-resize")
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel(L("调整歌词区域"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private var canResize: Bool {
        guard let window else { return false }
        return !isHiddenOrHasHiddenAncestor && !transition && !window.styleMask.contains(.fullScreen)
            && window.contentRect(forFrameRect: window.frame).width < 600
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard canResize, bounds.contains(local), let window else { return nil }
        return ownsBottomEdge(at: window.convertPoint(toScreen: convert(local, to: nil)), window: window) ? self : nil
    }
    override func resetCursorRects() {
        if canResize { addCursorRect(bounds, cursor: .resizeUpDown) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateIndicator(animated: true) }
    override func mouseExited(with event: NSEvent) { hovering = false; updateIndicator(animated: true) }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize); needsLayout = true
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        indicator.bounds = CGRect(x: 0, y: 0, width: 30, height: 3)
        indicator.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    private var indicatorReduceMotion: Bool {
#if FUSIONPLAY_UI_CHECKS
        if let testIndicatorReduceMotion { return testIndicatorReduceMotion }
#endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private func updateIndicator(animated: Bool) {
        let target: Float = canResize && (hovering || dragging) ? (dragging ? 0.7 : 0.3) : 0
        let current = indicator.presentation()?.opacity ?? indicator.opacity
        indicator.removeAnimation(forKey: "grip-opacity")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        indicator.opacity = target
        CATransaction.commit()
        guard animated, !indicatorReduceMotion, abs(current - target) > 0.001, window != nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current; fade.toValue = target
        fade.duration = target == 0 ? 0.4 : 0.2
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        indicator.add(fade, forKey: "grip-opacity")
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachWindow()
    }
    private func attachWindow() {
        guard observedWindow !== window else { return }
        invalidate(); observedWindow = window
        guard let window else { return }
        for name in [NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                     NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window,
                queue: .main) { [weak self] note in self?.windowChanged(note.name) })
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateIndicator(animated: false) }
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in self?.finishPointer() })
        // Claim the pointer before NSWindow enters its border-resize loop.
        // Once owned, drag/up remain ours even outside the original window.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if self.pointerResize != nil {
                if event.type == .leftMouseDragged { self.mouseDragged(with: event); return nil }
                if event.type == .leftMouseUp { self.mouseUp(with: event); return nil }
            }
            guard event.type == .leftMouseDown, self.canResize, let window = self.window,
                  window.isVisible, event.window === window || event.window == nil,
                  self.ownsBottomEdge(at: self.screenPoint(event), window: window) else { return event }
            self.mouseDown(with: event)
            return self.pointerResize == nil ? event : nil
        }
    }
    private func ownsBottomEdge(at point: NSPoint, window: NSWindow) -> Bool {
        let frame = window.frame
        // Leave side/corner resize targets native. AppKit's real bottom-edge
        // hot zone reaches outside the content view, below the window frame.
        return point.x >= frame.minX + 24 && point.x <= frame.maxX - 24
            && point.y >= frame.minY - 4 && point.y <= frame.minY + 14
    }
    private func screenPoint(_ event: NSEvent) -> NSPoint {
        if let source = event.window { return source.convertPoint(toScreen: event.locationInWindow) }
        // AppKit supplies screen coordinates when an event has no window.
        return event.locationInWindow
    }
    private func windowChanged(_ name: Notification.Name) {
        guard let window else { return }
        if name == NSWindow.willCloseNotification { invalidate(); return }
        if name == NSWindow.willEnterFullScreenNotification || name == NSWindow.willExitFullScreenNotification {
            interruptSnap()
            transition = true; generation &+= 1; pointerResize = nil; hovering = false
            setDragging(false); updateIndicator(animated: false); return
        }
        if name == NSWindow.didEnterFullScreenNotification || name == NSWindow.didExitFullScreenNotification {
            transition = false; updateIndicator(animated: false); return
        }
        // Top/side native resizing updates saved dimensions, never pane mode.
        if name == NSWindow.didResizeNotification, !dragging, expanded, canResize {
            remember(contentSize(window))
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard canResize, let window else { return }
        let point = screenPoint(event)
        guard ownsBottomEdge(at: point, window: window) else { return }
        generation &+= 1
        interruptSnap()
        let content = contentSize(window)
        remember(content)
        pointerResize = PointerResize(point: point, frame: window.frame, content: content)
    }
    override func mouseDragged(with event: NSEvent) {
        guard canResize, let window, var resize = pointerResize, !resize.rejected else { return }
        let point = screenPoint(event)
        let dx = point.x - resize.point.x, dy = resize.point.y - point.y
        if !resize.started {
            guard max(abs(dx), abs(dy)) >= 4 else { return }
            guard abs(dy) > abs(dx) * 1.15 else {
                resize.rejected = true; pointerResize = resize; return
            }
            resize.started = true; pointerResize = resize
            setDragging(true); releaseAspect(window)
        }
        let height = max(resize.content.width, resize.content.height + dy)
        if height > resize.content.width + 4 { setExpanded(true) }
        setContentHeight(height, width: resize.content.width, top: resize.frame.maxY,
                         left: resize.frame.minX, window: window)
    }
    override func mouseUp(with event: NSEvent) { finishPointer() }
    private func finishPointer() {
        guard let resize = pointerResize else { return }
        pointerResize = nil
        guard dragging, canResize, let window else { setDragging(false); return }
        settle(size: contentSize(window), top: resize.frame.maxY, left: resize.frame.minX)
    }
    private func settle(size: NSSize, top: CGFloat, left: CGFloat) {
        let pane = size.height - size.width
        let opens = pane >= Self.collapseThreshold
        let height = opens ? size.width + max(Self.minimumExpandedHeight, pane) : size.width
        if opens { rememberedPaneHeight = height - size.width }
        animateHeight(height, width: size.width, top: top, left: left, expanded: opens)
    }
    private func animateHeight(_ height: CGFloat, width: CGFloat, top: CGFloat, left: CGFloat, expanded opens: Bool) {
        guard canResize, let window else { setDragging(false); return }
        setDragging(true); releaseAspect(window)
        generation &+= 1; let token = generation
        settling = true
        let target = contentFrame(height, width: width, top: top, left: left, window: window)
        let complete: () -> Void = { [weak self, weak window] in
            guard let self, self.generation == token else { return }
            guard let window, self.window === window, self.canResize else {
                self.settling = false; self.setDragging(false); return
            }
            self.settling = false
            // Commit mode only after the physical resize has settled. Keep
            // ownership until SwiftUI can consume that final state next turn.
            self.setExpanded(opens)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token, self.pointerResize == nil, !self.settling else { return }
                self.setDragging(false)
            }
        }
        if abs(window.frame.height - target.height) < 0.5 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(target, display: true); complete()
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1)
                window.animator().setFrame(target, display: true)
            } completionHandler: { complete() }
        }
    }
    private func interruptSnap() {
        guard settling else { return }
        generation &+= 1; settling = false
        guard let window = window ?? observedWindow else { return }
        let frame = window.frame
        // Replace the active frame animation itself, not just its completion.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            window.animator().setFrame(frame, display: true)
        }
    }
    private func remember(_ size: NSSize) {
        let pane = size.height - size.width
        if expanded && pane >= Self.collapseThreshold { rememberedPaneHeight = max(Self.minimumExpandedHeight, pane) }
    }
    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value; onExpansionChanged(value)
    }
    private func setDragging(_ value: Bool) {
        guard dragging != value else { return }
        dragging = value; updateIndicator(animated: true); onDraggingChanged(value)
    }
    private func contentSize(_ window: NSWindow) -> NSSize { window.contentRect(forFrameRect: window.frame).size }
    private func releaseAspect(_ window: NSWindow) {
        window.aspectRatio = .zero; window.contentAspectRatio = .zero
        window.resizeIncrements = NSSize(width: 1, height: 1)
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
        window.contentMinSize = NSSize(width: 260, height: 260)
    }
    private func contentFrame(_ height: CGFloat, width: CGFloat, top: CGFloat, left: CGFloat, window: NSWindow) -> NSRect {
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
        return NSRect(x: left, y: top - size.height, width: size.width, height: size.height)
    }
    private func setContentHeight(_ height: CGFloat, width: CGFloat, top: CGFloat, left: CGFloat, window: NSWindow) {
        window.setFrame(contentFrame(height, width: width, top: top, left: left, window: window), display: true)
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard canResize, let window else { return false }
        let size = contentSize(window)
        setDragging(true); releaseAspect(window); setExpanded(true)
        animateHeight(size.width + max(Self.minimumExpandedHeight, rememberedPaneHeight), width: size.width,
                      top: window.frame.maxY, left: window.frame.minX, expanded: true)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard canResize, let window else { return false }
        let size = contentSize(window); remember(size)
        animateHeight(size.width, width: size.width, top: window.frame.maxY, left: window.frame.minX, expanded: false)
        return true
    }
    func invalidate() {
        interruptSnap()
        observations.forEach(NotificationCenter.default.removeObserver); observations = []
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        hovering = false
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor); self.mouseMonitor = nil }
        generation &+= 1; pointerResize = nil; settling = false; observedWindow = nil
        setDragging(false); updateIndicator(animated: false)
    }
    deinit {
        observations.forEach(NotificationCenter.default.removeObserver)
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }
}
