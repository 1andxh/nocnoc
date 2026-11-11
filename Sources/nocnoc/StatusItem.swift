import AppKit
import Combine
import SwiftUI

/// The menu-bar icon and its glass popover.
///
/// Why not SwiftUI's MenuBarExtra: its window sizes itself when it opens but
/// doesn't shrink when content goes away, so answering a card left the
/// popover half empty. Owning the status item and panel lets the popover
/// follow its content's height, keep Apple-style continuous corners, and
/// close itself when there's nothing left to do.
@MainActor
final class StatusItemController: NSObject {
    static let shared = StatusItemController()

    static let width: CGFloat = 360

    private var item: NSStatusItem!
    private var panel: GlassPanel?
    private var clickMonitor: Any?
    private var observer: AnyCancellable?

    func install() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])   // react on press, like system items
        item.button?.imagePosition = .imageLeading
        // objectWillChange fires *before* the change; read the new values on the next turn.
        observer = AppState.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        updateIcon()
    }

    private func updateIcon() {
        let state = AppState.shared
        let name = !state.waiting.isEmpty ? "exclamationmark.bubble.fill"
            : (state.away ? "bell.badge.fill" : "bell.slash")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "nocnoc")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.title = state.waiting.isEmpty ? "" : " \(state.waiting.count)"
    }

    // MARK: - Popover

    @objc private func toggle() {
        Log.info("menu-bar icon clicked (popover \(panel == nil ? "closed" : "open"))")
        if panel != nil { close() } else { open() }
    }

    func open() {
        guard panel == nil, let button = item.button, let buttonWindow = button.window else { return }

        let view = PopoverView(state: AppState.shared, onDone: { [weak self] in self?.close() })
        let height = NSHostingView(rootView: view).fittingSize.height
        let panel = GlassPanel(size: NSSize(width: Self.width, height: max(height, 120)))
        panel.setGlassContent(view.modifier(HeightReporter { [weak panel] h in
            guard h > 50 else { return }
            panel?.setHeightKeepingTop(h)
        }))
        panel.onCancel = { [weak self] in self?.close() }

        // Hang it under the menu-bar icon, kept on screen.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(anchor.midX - Self.width / 2, screen.minX + 8), screen.maxX - Self.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - 6 - panel.frame.height))

        self.panel = panel
        Log.info("popover opened")
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }

        // A click anywhere outside nocnoc closes it, like a real popover.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    func close() {
        guard let panel else { return }
        self.panel = nil
        Log.info("popover closed")
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }
}
