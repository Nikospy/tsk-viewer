import AppKit
import SwiftUI

/// A Spotlight-style panel under the menu bar icon. It takes the keyboard without activating the app,
/// so the system never hands focus back to the previous app (which closed the transient popover at once).
@MainActor
final class PanelWindow: NSPanel, NSWindowDelegate {
    private var closedAt = Date.distantPast

    init<Content: View>(rootView: Content) {
        super.init(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .utilityWindow
        delegate = self
        let hosting = NSHostingView(rootView: rootView
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)))
        hosting.sizingOptions = [.intrinsicContentSize]
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var isShown: Bool { isVisible }

    /// A click on the menu bar icon first takes the key away (closing the panel); don't reopen it right after.
    var justClosed: Bool { Date().timeIntervalSince(closedAt) < 0.3 }

    func show(below button: NSStatusBarButton) {
        guard let anchor = button.window?.convertToScreen(button.convert(button.bounds, to: nil)) else { return }
        let visible = (button.window?.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - frame.width / 2, visible.minX + 8), visible.maxX - frame.width - 8)
        present(at: NSPoint(x: x, y: anchor.minY - frame.height - 6))
    }

    /// Spotlight-style: centred on the screen under the mouse, slightly above the middle.
    func showCentered() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let y = min(visible.midY - frame.height / 2 + visible.height * 0.08, visible.maxY - frame.height - 8)
        present(at: NSPoint(x: visible.midX - frame.width / 2, y: max(y, visible.minY + 8)))
    }

    private func present(at origin: NSPoint) {
        setFrameOrigin(origin)
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        closedAt = Date()
        orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }
}
