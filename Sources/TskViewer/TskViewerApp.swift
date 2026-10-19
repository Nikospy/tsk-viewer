import AppKit
import Combine
import SwiftUI
import TskCore
import UserNotifications

@main
struct TskViewerApp: App {
    @NSApplicationDelegateAdaptor(ViewerDelegate.self) private var delegate
    var body: some Scene {
        // The app lives in the menu bar: no settings window at launch or restored from last time.
        Settings { SettingsView(model: delegate.model) }
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "tray", accessibilityDescription: L("Waiting for me", pl: "Czeka na mnie"))
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        model.closePanel = { [weak self] in self?.panel.hide() }
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
        if panel.isShown { panel.hide() } else if !panel.justClosed { showPanel() }
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
