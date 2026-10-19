import AppKit
import Combine
import SwiftUI
import TskCore
import UserNotifications

@main
struct TskViewerApp: App {
    @NSApplicationDelegateAdaptor(ViewerDelegate.self) private var delegate
    var body: some Scene {
        // The delegate owns every window, so the menu bar icon can open them; SwiftUI still wants one scene.
        Settings { EmptyView() }
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

@MainActor
final class ViewerDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = ViewerModel()
    private var statusItem: NSStatusItem?
    private lazy var panel = PanelWindow(rootView: ViewerPanel(model: model))
    private var subscriptions: Set<AnyCancellable> = []
    private var notificationCenter: UNUserNotificationCenter?
    private var namesWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: L("Waiting for me", pl: "Czeka na mnie"))
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        model.closePanel = { [weak self] in self?.panel.hide() }
        model.openAgentNames = { [weak self] in self?.showAgentNames() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.$tasks.sink { [weak self] tasks in
            let count = TaskGrouping.attentionCount(tasks)
            self?.statusItem?.button?.image = NSImage(systemSymbolName: count == 0 ? "tray" : "tray.full",
                                                      accessibilityDescription: L("Waiting for me", pl: "Czeka na mnie"))
            self?.statusItem?.button?.title = count == 0 ? "" : " \(count)"
            self?.statusItem?.button?.toolTip = L("Waiting for me", pl: "Czeka na mnie") + ": \(count)"
        }.store(in: &subscriptions)
        configureNotifications()
        GlobalHotKey.shared.action = { [weak self] in self?.toggleFromShortcut() }
        GlobalHotKey.shared.register(Shortcut.stored)
        model.startPolling()
    }

    /// Opening the app again (Finder, Spotlight) shows the panel instead of an empty settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    @objc private func togglePanel() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu()
            return
        }
        if panel.isShown { panel.hide() } else if !panel.justClosed { showPanel() }
    }

    /// Right-click on the menu bar icon: what does not belong in the panel itself.
    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: L("Name agents", pl: "Nazwij agentów"), action: #selector(showAgentNames), keyEquivalent: "").target = self
        menu.addItem(withTitle: L("Settings", pl: "Ustawienia"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit TskViewer", pl: "Zakończ TskViewer"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func showAgentNames() {
        show(&namesWindow, title: L("Name agents", pl: "Nazwij agentów")) { close in AgentNamesView(model: self.model, close: close) }
        Task { await model.refresh() }
    }

    @objc private func showSettings() {
        show(&settingsWindow, title: L("Settings", pl: "Ustawienia")) { close in SettingsView(model: self.model, close: close) }
    }

    /// A fresh view each time, so drafts from a cancelled visit do not come back.
    private func show<Content: View>(_ slot: inout NSWindow?, title: String, content: (@escaping () -> Void) -> Content) {
        panel.hide()
        let window = slot ?? {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Theme.panel)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = true
            window.isRestorable = false
            return window
        }()
        slot = window
        window.title = title
        window.contentViewController = NSHostingController(rootView: content { [weak window] in window?.close() })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The shortcut opens the panel in the middle of the screen; the menu bar icon opens it under the icon.
    private func toggleFromShortcut() {
        if panel.isShown { panel.hide() } else { panel.showCentered() }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        panel.show(below: button)
    }

    private func configureNotifications() {
        // UNUserNotificationCenter can raise an ObjC exception for a bare SwiftPM executable.
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        notificationCenter = center
        center.delegate = self
        model.notify = { [weak self] events in self?.post(events) }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private func post(_ events: [TaskTransition]) {
        guard let center = notificationCenter else { return }
        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = "\(event.project) · \(event.status.displayName) (\(event.status.rawValue))"
            content.userInfo = ["taskID": event.task.id]
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { _ in }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["taskID"] as? String else { return }
        await openNotification(id)
    }

    private func openNotification(_ id: String) async {
        showPanel()
        await model.select(id, reload: true)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

extension TskStatus {
    var displayName: String {
        switch self {
        case .open: L("Open", pl: "Otwarte")
        case .ready: L("Ready to work", pl: "Gotowe do pracy")
        case .started: L("In progress", pl: "W trakcie")
        case .blocked: L("Waiting for a reply", pl: "Czeka na odpowiedź")
        case .review: L("To accept", pl: "Do akceptacji")
        case .done: L("Done", pl: "Ukończone")
        case .unknown(let value): value
        }
    }

    var symbol: String {
        switch self {
        case .blocked: "questionmark.bubble"
        case .review: "checkmark.bubble"
        case .done: "checkmark.circle"
        case .started: "play.circle"
        default: "circle"
        }
    }
}
