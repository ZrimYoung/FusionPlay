import AppKit
import Combine
import SwiftUI

/// Own the transparent window rather than layering clear glass over the opaque
/// MenuBarExtra shell. The status item and hosted controls each keep one identity.
@MainActor
final class MenuPanelController: NSObject, NSWindowDelegate {
    private let model: ReceiverModel
    private let defaults: UserDefaults
    private var openWindowAction: (String) -> Void
    private var statusItem: NSStatusItem?
    private var panel: MenuWindow!
    private var host: NSHostingView<AnyView>!
    private var material: NSView?
    private var materialKey = ""
    private var preferredHeight: CGFloat = 174
    private var subscriptions = Set<AnyCancellable>()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var invalidated = false

    init(model: ReceiverModel, openWindow: @escaping (String) -> Void,
         defaults: UserDefaults = .standard) {
        self.model = model; self.defaults = defaults; self.openWindowAction = openWindow
        super.init()
        panel = MenuWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: preferredHeight),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isFloatingPanel = true; panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false; panel.level = .statusBar
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.setAccessibilityLabel("FusionPlay")
        host = NSHostingView(rootView: AnyView(MenuHostedContent(model: model,
            onOpenWindow: { [weak self] id in self?.openDestination(id) },
            onHeight: { [weak self] height in self?.updateHeight(height) })
            .defaultAppStorage(defaults)))
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        observe(NotificationCenter.default, name: UserDefaults.didChangeNotification, object: defaults) { [weak self] in
            self?.syncPreferences()
        }
        observe(NSWorkspace.shared.notificationCenter,
                name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.syncPreferences()
        }
        observe(NotificationCenter.default, name: NSApplication.didResignActiveNotification) { [weak self] in
            self?.dismissUnlessPresentingSheet()
        }
        observe(NotificationCenter.default, name: NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.close()
        }
        model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateStatusItem()
        }.store(in: &subscriptions)
        syncPreferences()
    }

    func setOpenWindowAction(_ action: @escaping (String) -> Void) { openWindowAction = action }

    func syncPreferences() {
        guard !invalidated else { return }
        let visible = defaults.object(forKey: "showMenuBarIcon") as? Bool ?? true
        if visible && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "FusionPlayReceiverMenu"
            statusItem = item
            item.button?.target = self; item.button?.action = #selector(toggleFromStatusItem(_:))
            item.button?.imagePosition = .imageOnly
            item.button?.setAccessibilityLabel("FusionPlay")
        } else if !visible, let item = statusItem {
            close(); NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
        updateStatusItem()
        updateMaterial()
    }

    private func updateStatusItem() {
        let state: MenuPlaybackState = model.snapshot?.phase == .playing ? .playing : model.snapshot?.phase == .paused ? .paused : .idle
        statusItem?.button?.image = AppBrand.menuIcon(for: state)
        let label = "FusionPlay · " + L(model.phaseLabel)
        statusItem?.button?.toolTip = label
        statusItem?.button?.setAccessibilityLabel(label)
    }

    func show() {
        guard !invalidated, let button = statusItem?.button, let window = button.window else { return }
        position(relativeTo: window.convertToScreen(button.convert(button.bounds, to: nil)),
                 visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame)
        panel.makeKeyAndOrderFront(nil)
        // AppKit otherwise focuses the first SwiftUI button automatically and
        // paints a blue ring around the cover when keyboard navigation is on.
        // Start without a selected control; Tab still enters the normal key loop.
        panel.makeFirstResponder(nil)
        button.highlight(true)
        installEventMonitors()
    }

    @objc private func toggleFromStatusItem(_ sender: Any?) { toggle() }
    func toggle() { if panel.isVisible { close() } else { show() } }

    func close() {
        panel.orderOut(nil); statusItem?.button?.highlight(false)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; close()
        subscriptions.removeAll()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
        panel.delegate = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        // A sheet temporarily takes key focus; closing its parent would dismiss
        // the user's quit confirmation before they can answer it.
        DispatchQueue.main.async { [weak self] in self?.dismissUnlessPresentingSheet() }
    }

    private func dismissUnlessPresentingSheet() {
        if panel.isVisible && panel.attachedSheet == nil { close() }
    }

    private func openDestination(_ id: String) { close(); openWindowAction(id) }

    private func updateMaterial() {
        let style = MenuPanelBackgroundStyle.resolve(defaults.string(forKey: MenuPanelBackgroundStyle.storageKey) ?? MenuPanelBackgroundStyle.defaultValue.rawValue)
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let key = "\(style.rawValue):\(reduced)"
        guard key != materialKey else { return }
        materialKey = key
#if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView { glass.contentView = nil }
#endif
        host.removeFromSuperview()
        let root: NSView
        var windowShadow = true
#if compiler(>=6.2)
        if #available(macOS 26.0, *), style != .frosted, !reduced {
            let glass = NSGlassEffectView()
            glass.style = style == .regularGlass ? .regular : .clear
            glass.cornerRadius = 18
            glass.tintColor = nil
            glass.contentView = host
            // Native glass already draws its optical edge. A second window
            // shadow makes clear glass look like it has a dark extra rim.
            windowShadow = false
            root = glass
        } else { root = makeFrostedMaterial() }
#else
        root = makeFrostedMaterial()
#endif
        root.frame = NSRect(origin: .zero, size: panel.frame.size)
        root.autoresizingMask = [.width, .height]
        if host.superview == nil { root.addSubview(host) }
        host.frame = root.bounds
        material = root; panel.contentView = root
        panel.hasShadow = windowShadow
        panel.invalidateShadow()
    }

    private func makeFrostedMaterial() -> NSView {
        let view = NSVisualEffectView()
        view.material = .popover; view.blendingMode = .behindWindow; view.state = .active
        view.wantsLayer = true; view.layer?.cornerRadius = 18; view.layer?.masksToBounds = true
        return view
    }

    private func updateHeight(_ height: CGFloat) {
        guard height.isFinite, height >= 80, abs(preferredHeight - height) > 0.5 else { return }
        preferredHeight = ceil(height)
        guard panel.isVisible, let button = statusItem?.button, let window = button.window else {
            panel.setContentSize(NSSize(width: 280, height: preferredHeight)); return
        }
        position(relativeTo: window.convertToScreen(button.convert(button.bounds, to: nil)),
                 visibleFrame: (window.screen ?? NSScreen.main)?.visibleFrame)
    }

    private func position(relativeTo anchor: NSRect, visibleFrame: NSRect?) {
        let visible = visibleFrame ?? anchor.insetBy(dx: -500, dy: -500)
        panel.setFrame(Self.menuFrame(anchor: anchor, visibleFrame: visible,
                                     size: NSSize(width: 280, height: preferredHeight)), display: panel.isVisible)
    }

    static func menuFrame(anchor: NSRect, visibleFrame: NSRect, size: NSSize) -> NSRect {
        let width = min(size.width, max(1, visibleFrame.width - 12))
        let height = min(size.height, max(1, visibleFrame.height - 12))
        return NSRect(x: min(max(anchor.midX - width / 2, visibleFrame.minX + 6), visibleFrame.maxX - width - 6),
                      y: min(max(anchor.minY - height - 6, visibleFrame.minY + 6), visibleFrame.maxY - height - 6),
                      width: width, height: height)
    }

    private func installEventMonitors() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 && self.panel.attachedSheet == nil { self.close(); return nil }
            } else if self.panel.attachedSheet == nil,
                      event.window !== self.panel, event.window !== self.statusItem?.button?.window {
                self.close()
            }
            return event
        }
        // Mouse-only observation needs no keyboard monitoring/accessibility grant.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismissUnlessPresentingSheet()
        }
    }

    private func observe(_ center: NotificationCenter, name: Notification.Name, object: Any? = nil,
                         action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { _ in
            DispatchQueue.main.async { action() }
        }
        observers.append((center, token))
    }

#if FUSIONPLAY_UI_CHECKS
    var testHostIdentity: ObjectIdentifier { ObjectIdentifier(host) }
    var testPanel: NSPanel { panel }
    var testMaterial: NSView? { material }
    var testHasStatusItem: Bool { statusItem != nil }
    func testOpenDestination(_ id: String) { openDestination(id) }
#endif
}

private final class MenuWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct MenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 174
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct MenuHostedContent: View {
    @AppStorage("appLanguage") private var language = "zh-Hans"
    @ObservedObject var model: ReceiverModel
    var onOpenWindow: (String) -> Void
    var onHeight: (CGFloat) -> Void
    var body: some View {
        ReceiverPanel(model: model, onOpenWindow: onOpenWindow)
            .appTypography().environment(\.locale, Locale(identifier: language))
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in Color.clear.preference(key: MenuHeightKey.self, value: geometry.size.height) }
            }.onPreferenceChange(MenuHeightKey.self) { height in
                DispatchQueue.main.async { onHeight(height) }
            }
    }
}
