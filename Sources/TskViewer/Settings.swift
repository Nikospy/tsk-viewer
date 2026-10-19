import AppKit
import SwiftUI
import TskCore

/// Settings in the same Grafit / iA Writer Mono language as the panel.
struct SettingsView: View {
    @ObservedObject var model: ViewerModel
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var seconds = 10.0
    @State private var shortcut = Shortcut.stored
    @State private var language = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("tsk").font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                Text("~").foregroundStyle(Theme.faint)
                Text(L("settings", pl: "ustawienia")).font(Theme.mono(13, .semibold))
            }
            .padding(.bottom, 22)

            row(L("shortcut", pl: "skrót"), hint: L("opens and closes the panel from any app · ⌫ removes the shortcut", pl: "otwiera i zamyka panel z dowolnej aplikacji · ⌫ usuwa skrót")) {
                ShortcutRecorder(shortcut: $shortcut)
            }
            row(L("tsk program", pl: "program tsk"), hint: L("empty: TSK_PATH, then /opt/homebrew/bin/tsk · now: ", pl: "puste: TSK_PATH, potem /opt/homebrew/bin/tsk · teraz: ") + model.effectivePath) {
                field { TextField("", text: $path, prompt: Text("/opt/homebrew/bin/tsk").foregroundColor(Theme.faint)) }
            }
            row(L("refresh", pl: "odświeżanie"), hint: L("how often the app reads the board, in seconds · 2–3600, default 10", pl: "co ile sekund apka czyta tablicę · 2–3600, domyślnie 10")) {
                HStack(spacing: 8) {
                    field { TextField("", value: $seconds, format: .number).multilineTextAlignment(.trailing) }
                        .frame(width: 80)
                    Text("s").foregroundStyle(Theme.faint)
                }
            }
            row(L("language", pl: "język"), hint: L("also the language of replies in notes and of messages to agents", pl: "także język odpowiedzi w notatkach i wiadomości do agentów")) {
                Picker("", selection: $language) {
                    Text(L("system", pl: "systemowy")).tag("system")
                    Text("English").tag("en")
                    Text("polski").tag("pl")
                }
                .labelsHidden().fixedSize()
            }
            if !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && path != model.executableSetting {
                Text(L("changing the program closes the details and drops draft replies", pl: "zmiana programu zamknie szczegóły i usunie robocze odpowiedzi"))
                    .font(Theme.mono(11)).foregroundStyle(Theme.ask)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 8) {
                Spacer()
                Button(L("cancel", pl: "anuluj")) { dismiss() }
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(L("save", pl: "zapisz")) {
                    model.saveSettings(path: path, seconds: seconds, language: language)
                    dismiss()
                }
                .buttonStyle(SolidButtonStyle(fill: Theme.accent, hoverFill: Theme.accentHover, foreground: Theme.accentText))
                .keyboardShortcut(.defaultAction)
                .disabled(model.saving || model.loading || model.loadingDetail)
            }
            .padding(.top, 8)
        }
        .font(Theme.mono(13))
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 24)
        .frame(width: 520)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
        .background(WindowStyler())
        .onAppear {
            path = model.executableSetting
            seconds = model.interval
            language = model.languageSetting
            shortcut = Shortcut.stored
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func row<Content: View>(_ label: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 16) {
                Text(label).foregroundStyle(Theme.dim).frame(width: 110, alignment: .leading)
                content()
                Spacer(minLength: 0)
            }
            Text(hint).font(Theme.mono(11)).foregroundStyle(Theme.faint)
                .padding(.leading, 126)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 18)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .textFieldStyle(.plain)
            .font(Theme.mono(13))
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Click, then press the combination; Esc cancels, ⌫ removes the shortcut.
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            Text(recording ? L("press a shortcut…", pl: "naciśnij skrót…") : shortcut?.label ?? L("none", pl: "brak"))
                .font(Theme.mono(13, recording ? .regular : .semibold))
                .foregroundStyle(recording ? Theme.accent : shortcut == nil ? Theme.faint : Theme.text)
                .frame(minWidth: 140, minHeight: 32)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(recording ? Theme.selection : hovered ? Theme.hover : Theme.raised))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(recording ? Theme.accent : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: // Esc
                stop()
            case 51, 117: // ⌫, ⌦
                apply(nil)
            default:
                guard let recorded = Shortcut(event: event) else { NSSound.beep(); return nil }
                apply(recorded)
            }
            return nil
        }
    }

    private func apply(_ value: Shortcut?) {
        shortcut = value
        Shortcut.store(value)
        GlobalHotKey.shared.register(value)
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}

/// Blends the settings window's title bar into the Grafit background.
private struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Theme.panel)
            window.appearance = NSAppearance(named: .darkAqua)
            window.isMovableByWindowBackground = true
            window.isRestorable = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
