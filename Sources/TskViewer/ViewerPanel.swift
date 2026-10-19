import AppKit
import SwiftUI
import TskCore

/// Prototype A, "Terminal": one monospace face, hierarchy by brightness rather than size.
struct ViewerPanel: View {
    @ObservedObject var model: ViewerModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Hairline()
            if let error = model.error { ErrorBanner(text: error) }
            if model.groups.isEmpty {
                BoardEmptyState(loading: model.loading && model.lastRefresh == nil, showingAll: model.includeOthers,
                                dispatch: model.dispatch)
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 292)
                    Rectangle().fill(Theme.line).frame(width: 1)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .font(Theme.mono(13))
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .frame(width: 780, height: 540)
        .background(Theme.panel)
        .focusEffectDisabled()
        .environment(\.colorScheme, .dark)
        .id(model.language)
        .onExitCommand { model.closePanel?() }
        .onChange(of: visibleIDs, initial: true) { _, ids in keepSelectionVisible(ids) }
    }

    private var visibleIDs: [String] { model.groups.flatMap { $0.tasks.map(\.id) } }

    /// Opening the panel lands on the first task; a task that leaves the list hands over to the next one.
    private func keepSelectionVisible(_ ids: [String]) {
        guard !model.saving else { return }
        if let id = model.selectedID, ids.contains(id) { return }
        if let first = ids.first { Task { await model.select(first) } } else { model.selectedID = nil }
    }

    private func refresh() async {
        await model.refresh()
        if let id = model.selectedID { await model.select(id, reload: true) }
    }

    private var refreshHelp: String {
        let refresh = L("Refresh (⌘R)", pl: "Odśwież (⌘R)")
        guard let date = model.lastRefresh else { return refresh }
        return refresh + L(" · last read ", pl: " · ostatni odczyt ") + date.formatted(date: .omitted, time: .shortened)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("tsk").font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
            Text("~").foregroundStyle(Theme.faint)
            Text(L("waiting for me", pl: "czeka na mnie")).font(Theme.mono(13, .semibold))
            Text("[\(model.attentionCount)]").foregroundStyle(Theme.faint)
            Spacer()
            HStack(spacing: 2) {
                Button(L("for me", pl: "dla mnie")) { model.includeOthers = false }
                    .buttonStyle(GhostButtonStyle(active: !model.includeOthers))
                Button(L("all", pl: "wszystkie")) { model.includeOthers = true }
                    .buttonStyle(GhostButtonStyle(active: model.includeOthers))
            }
            Button { Task { await refresh() } } label: {
                ZStack {
                    if model.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                }
                .frame(width: 14, height: 16)
            }
            .buttonStyle(GhostButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.loading || model.saving || model.loadingDetail)
            .help(refreshHelp)
            Menu {
                Button(L("Name agents", pl: "Nazwij agentów")) { model.openAgentNames?() }
                Button(L("Settings", pl: "Ustawienia")) { model.openSettings?() }
                Divider()
                Button(L("Quit TskViewer", pl: "Zakończ TskViewer")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .frame(width: 26, height: 26)
            .help(L("More", pl: "Więcej"))
        }
        .padding(.leading, 18).padding(.trailing, 12)
        .frame(height: 44)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.groups) { group in
                        HStack(spacing: 8) {
                            Text(group.title)
                            DashedRule()
                            Text("\(group.tasks.count)")
                        }
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.faint)
                        .padding(.horizontal, 10)
                        .padding(.top, group.id == model.groups.first?.id ? 2 : 14).padding(.bottom, 6)
                        ForEach(group.tasks) { task in
                            TaskRow(task: task, selected: model.selectedID == task.id,
                                    checked: model.checked.contains(task.id)) { model.toggleCheck(task.id) }
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.command) {
                                        model.toggleCheck(task.id)
                                    } else {
                                        // Only a deliberate click clears the last send result; automatic hand-over keeps it.
                                        if model.selectedID != task.id { model.dispatch = nil }
                                        Task { await model.select(task.id) }
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            Hairline()
            Group {
                if model.checked.isEmpty {
                    Text("$ \(model.lastCommand ?? "tsk list --all --json")")
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                } else {
                    HStack(spacing: 8) {
                        Text("[x] \(model.checked.count) " + L("checked", pl: "zaznaczone")).foregroundStyle(Theme.accent)
                        Text("·")
                        Button(L("clear", pl: "wyczyść")) { model.clearChecks() }.buttonStyle(LinkTextStyle())
                    }
                }
            }
            .font(Theme.mono(11)).foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 9)
        }
        .background(Theme.side)
        .disabled(model.saving)
    }

    @ViewBuilder private var detail: some View {
        if let detail = model.detail {
            TaskDetail(model: model, detail: detail)
                .id(detail.task.id)
        } else if model.loadingDetail {
            ProgressView().controlSize(.small)
        } else if let error = model.detailError {
            VStack(spacing: 6) {
                Text(L("cannot read the task", pl: "nie można odczytać zadania")).foregroundStyle(Theme.danger)
                Text(error).font(Theme.mono(11.5)).foregroundStyle(Theme.dim).textSelection(.enabled)
            }
            .padding(24)
        } else {
            Text(L("pick a task", pl: "wybierz zadanie")).foregroundStyle(Theme.faint)
        }
    }
}

// MARK: - List

private struct TaskRow: View {
    let task: TskTask
    let selected: Bool
    let checked: Bool
    let onCheck: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The status glyph turns into a checkbox on hover; ⌘-click on the row does the same.
            Group {
                if checked || hovered {
                    Button(action: onCheck) {
                        Text(checked ? "[x]" : "[ ]")
                            .foregroundStyle(checked ? Theme.accent : Theme.dim)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Check to send several tasks to the agent (⌘-click)", pl: "Zaznacz, żeby wysłać kilka zadań agentowi (⌘-klik)"))
                } else {
                    Text(task.status.glyph).foregroundStyle(task.status.tint)
                }
            }
            .font(Theme.mono(13, .bold))
            .frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(Theme.mono(13, .medium))
                    .lineLimit(1).truncationMode(.tail)
                (Text("\(task.id) · ").foregroundColor(Theme.faint)
                    + Text(task.status.terminalLabel).foregroundColor(task.status.tint))
                    .font(Theme.mono(11.5))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.selection : hovered ? Theme.hover : .clear)
        )
        .opacity(task.status.needsAttention || checked ? 1 : 0.7)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

private struct DashedRule: View {
    var body: some View {
        GeometryReader { proxy in
            Path { path in
                path.move(to: CGPoint(x: 0, y: proxy.size.height / 2))
                path.addLine(to: CGPoint(x: proxy.size.width, y: proxy.size.height / 2))
            }
            .stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .frame(height: 1)
    }
}

// MARK: - Detail

private struct TaskDetail: View {
    @ObservedObject var model: ViewerModel
    let detail: ViewerModel.Detail

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    (Text("\(detail.task.id) · \(detail.task.projectName) · ").foregroundColor(Theme.faint)
                        + Text(detail.task.status.rawValue).foregroundColor(detail.task.status.tint))
                        .font(Theme.mono(11.5))
                    Text(detail.task.title)
                        .font(Theme.mono(17, .bold))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 10)
                    Group {
                        if detail.task.notes.isEmpty {
                            Text(L("no notes", pl: "brak notatek")).foregroundStyle(Theme.faint)
                        } else {
                            NotesView(source: detail.task.notes)
                        }
                    }
                    .padding(.top, 16)
                    if !detail.task.steps.isEmpty { steps.padding(.top, 18) }
                    if let error = model.detailError {
                        Callout(text: error, color: Theme.danger).padding(.top, 18)
                    }
                    if let message = detail.message {
                        Callout(text: message, color: Theme.dim).padding(.top, 18)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.vertical, 22)
            }
            .scrollIndicators(.never)
            ActionBar(model: model, detail: detail)
        }
    }

    private var steps: some View {
        let done = detail.task.steps.filter(\.done).count
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("steps", pl: "kroki") + " \(done)/\(detail.task.steps.count)")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.faint)
            ForEach(detail.task.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(step.done ? "[x]" : "[ ]").foregroundStyle(step.done ? Theme.ok : Theme.faint)
                    Text(step.title)
                        .strikethrough(step.done, color: Theme.faint)
                        .foregroundStyle(step.done ? Theme.faint : Theme.text)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Decision bar

/// The bottom bar holds the only decisions on screen: a reply prompt and one primary action.
private struct ActionBar: View {
    @ObservedObject var model: ViewerModel
    let detail: ViewerModel.Detail
    @FocusState private var replyFocused: Bool
    @State private var confirmingAccept = false

    private var available: [TaskAction] { TaskAction.available(for: detail.task.status) }
    private var quickAction: TaskAction? { available.first { !$0.requiresReply } }
    private var replyAction: TaskAction? { available.first { $0.requiresReply } }
    private var hasText: Bool { !detail.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            AgentStrip(model: model)
                .padding(.horizontal, 16).padding(.top, 10)
            Group {
                if detail.requiresInspection {
                    inspection
                } else if detail.retry != nil {
                    retry
                } else if available.isEmpty {
                    Text(L("view only — the agent changes this status", pl: "tylko do podglądu — ten status zmienia agent"))
                        .font(Theme.mono(12)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    composer
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
        }
        .background(Theme.side)
        .disabled(model.saving)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(Theme.replyMarker).font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                    TextField("", text: Binding(get: { model.detail?.reply ?? "" }, set: { model.setReply($0) }),
                              prompt: Text(replyAction == .sendBack ? L("what to fix…", pl: "uwagi do poprawki…") : L("reply to the agent…", pl: "odpowiedz agentowi…"))
                                .foregroundColor(Theme.faint))
                        .textFieldStyle(.plain)
                        .font(Theme.mono(13))
                        .focused($replyFocused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "return")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(hasText ? Theme.accent : Theme.faint)
                            .frame(width: 26, height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(hasText ? Theme.selection : .clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasText)
                    .help(replyAction?.title ?? "")
                }
                .padding(.leading, 12).padding(.trailing, 6).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(replyFocused ? Theme.accent : Theme.line, lineWidth: 1)
                )
                .shadow(color: replyFocused ? Theme.accent.opacity(0.18) : .clear, radius: 4)
                .animation(.easeOut(duration: 0.15), value: replyFocused)
                if let quickAction { quickButton(quickAction) }
            }
            Text(hint).font(Theme.mono(11)).foregroundStyle(Theme.faint)
        }
    }

    @ViewBuilder private func quickButton(_ action: TaskAction) -> some View {
        if model.saving {
            ProgressView().controlSize(.small).frame(width: 112, height: 38)
        } else {
            Button {
                if action == .accept && !confirmingAccept {
                    confirmingAccept = true
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        confirmingAccept = false
                    }
                } else {
                    confirmingAccept = false
                    model.choose(action)
                }
            } label: {
                Text(confirmingAccept ? L("sure?", pl: "na pewno?") : action.title.lowercased())
            }
            .buttonStyle(quickStyle(action))
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func quickStyle(_ action: TaskAction) -> SolidButtonStyle {
        if confirmingAccept { return SolidButtonStyle(fill: Theme.ask, hoverFill: Theme.ask, foreground: Theme.panel) }
        if action == .accept { return SolidButtonStyle(fill: Theme.ok, hoverFill: Theme.okHover, foreground: Theme.okText) }
        return SolidButtonStyle(fill: Theme.accent, hoverFill: Theme.accentHover, foreground: Theme.accentText)
    }

    private var hint: String {
        if confirmingAccept { return L("click again to close the task", pl: "kliknij jeszcze raz, żeby zamknąć zadanie") }
        let prefix = Language.current.replyPrefix
        let quick = "⌘⏎ " + (quickAction?.title.lowercased() ?? "")
        if let agent = model.targetAgent, model.checked.isEmpty {
            let name = agent.name ?? agent.folder
            return hasText ? L("⏎ sends · the text goes to the notes as “\(prefix)” and to \(name)", pl: "⏎ wysyła · tekst trafi do notatek jako „\(prefix)” i do \(name)")
                : quick + L(" · \(name) gets a message", pl: " · \(name) dostanie wiadomość")
        }
        if hasText { return L("⏎ sends · the text goes to the notes as “\(prefix)”, the task returns to the agent", pl: "⏎ wysyła · tekst trafi do notatek jako „\(prefix)”, zadanie wraca do agenta") }
        return quick + (quickAction == .accept
            ? L(" · or write what to fix", pl: " · albo napisz, co poprawić")
            : L(" · or reply in your own words", pl: " · albo odpowiedz własnymi słowami"))
    }

    private func send() {
        guard hasText, let replyAction else { return }
        model.choose(replyAction)
        Task { await model.sendReply() }
    }

    private var retry: some View {
        HStack(spacing: 12) {
            Text(L("reply saved, status unchanged", pl: "odpowiedź zapisana, status bez zmian")).font(Theme.mono(12)).foregroundStyle(Theme.ask)
            Spacer()
            Button(L("retry status", pl: "ponów status")) { Task { await model.retryStatus() } }
                .buttonStyle(SolidButtonStyle(fill: Theme.accent, hoverFill: Theme.accentHover, foreground: Theme.accentText))
                .help(L("Retrying does not append the reply a second time.", pl: "Ponowienie nie dopisuje odpowiedzi drugi raz."))
        }
    }

    private var inspection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("unknown whether the reply was saved — check the notes before sending it again", pl: "nie wiadomo, czy odpowiedź się zapisała — sprawdź notatki, zanim wyślesz ją ponownie"))
                .font(Theme.mono(12)).foregroundStyle(Theme.ask)
            if !detail.reply.isEmpty {
                Text("\(Theme.replyMarker) \(detail.reply)").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                    .textSelection(.enabled).lineLimit(3)
            }
            Button(L("checked — read the fresh state", pl: "sprawdziłem — odczytaj świeży stan")) { Task { await model.acknowledgeInspection() } }
                .buttonStyle(GhostButtonStyle(active: true))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agent

/// Picks the Herdr agent that hears about decisions and gets tasks to discuss.
private struct AgentStrip: View {
    @ObservedObject var model: ViewerModel

    private var split: (matching: [HerdrAgent], others: [HerdrAgent]) { model.agentSplit }
    private var count: Int { model.dispatchTasks.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(L("to agent ›", pl: "do agenta ›")).foregroundStyle(Theme.faint)
                if model.agents.isEmpty {
                    Text(L("no herdr agents", pl: "brak agentów herdr")).foregroundStyle(Theme.faint)
                        .help(model.agentError ?? L("Herdr reports no agents.", pl: "Herdr nie zgłasza żadnego agenta."))
                } else {
                    picker
                }
                Spacer(minLength: 8)
                if model.sendingToAgent {
                    ProgressView().controlSize(.mini).frame(width: 60)
                } else {
                    Button(model.checked.isEmpty ? L("discuss", pl: "omów") : L("discuss checked (\(count))", pl: "omów zaznaczone (\(count))")) {
                        Task { await model.sendForDiscussion() }
                    }
                    .buttonStyle(GhostButtonStyle(active: !model.checked.isEmpty))
                    .disabled(model.targetAgent?.reachable != true || count == 0)
                    .help(L("Sends the tasks to the agent to discuss and carry out; the tsk status does not change.", pl: "Wysyła zadania agentowi do omówienia i realizacji; status w tsk się nie zmienia."))
                }
            }
            .font(Theme.mono(12))
            if let pane = model.senderPane, model.sender?.reachable != true {
                Text(model.sender == nil
                     ? L("the agent that asked (\(pane)) is gone — pick another", pl: "agenta, który pytał (\(pane)), już nie ma — wybierz innego")
                     : L("the agent that asked is not reachable now", pl: "agent, który pytał, jest teraz nieosiągalny"))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.faint)
            }
            if let dispatch = model.dispatch {
                Text(dispatch.text)
                    .font(Theme.mono(11))
                    .foregroundStyle(dispatch.ok ? Theme.ok : Theme.danger)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var picker: some View {
        Menu {
            if !split.matching.isEmpty {
                Section(L("in this project", pl: "w tym projekcie")) { ForEach(split.matching) { item($0) } }
            }
            if !split.others.isEmpty {
                Section(L("others", pl: "pozostałe")) { ForEach(split.others) { item($0) } }
            }
            Divider()
            Button(L("Name agents", pl: "Nazwij agentów")) { model.openAgentNames?() }
            Button(L("no agent", pl: "bez agenta")) { model.chooseAgent(nil) }
        } label: {
            HStack(spacing: 6) {
                Text(model.targetAgent.map(model.agentLabel) ?? L("pick…", pl: "wybierz…"))
                    .foregroundStyle(model.targetAgent == nil ? Theme.faint : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.faint)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("The agent gets a message after agree, accept, a reply and the “discuss” button. Defaults to the agent that asked, else the one remembered for the project.", pl: "Agent dostaje wiadomość po zgodzie, akceptacji, odpowiedzi i przycisku „omów”. Domyślnie ten, który pytał, inaczej zapamiętany dla projektu."))
    }

    private func item(_ agent: HerdrAgent) -> some View {
        Button {
            model.chooseAgent(agent.paneID)
        } label: {
            let text = model.agentLabel(agent) + (agent.supported ? "" : L(" · unsupported", pl: " · nieobsługiwany"))
            if agent.paneID == model.targetPane { Label(text, systemImage: "checkmark") } else { Text(text) }
        }
        .disabled(!agent.reachable)
    }
}

// MARK: - Small pieces

private struct LinkTextStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovered ? Theme.text : Theme.dim)
            .underline(hovered)
            .onHover { hovered = $0 }
    }
}

private struct Callout: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(Theme.mono(12))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.1)))
    }
}

private struct ErrorBanner: View {
    let text: String
    var body: some View {
        Text("! \(text)")
            .font(Theme.mono(12))
            .foregroundStyle(Theme.danger)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Theme.danger.opacity(0.1))
    }
}

private struct BoardEmptyState: View {
    let loading: Bool
    let showingAll: Bool
    /// Answering the last task empties the board; the send result must still be visible.
    let dispatch: (text: String, ok: Bool)?
    var body: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Text(showingAll ? L("the board is empty", pl: "tablica jest pusta") : L("✓ all done", pl: "✓ wszystko załatwione"))
                    .font(Theme.mono(15, .bold))
                    .foregroundStyle(showingAll ? Theme.dim : Theme.ok)
                Text(showingAll ? L("there are no live tasks", pl: "nie ma żadnych żywych zadań") : L("nothing waits for your reply or acceptance", pl: "nic nie czeka na twoją odpowiedź ani akceptację"))
                    .foregroundStyle(Theme.dim)
                if let dispatch {
                    Text(dispatch.text)
                        .font(Theme.mono(11))
                        .foregroundStyle(dispatch.ok ? Theme.ok : Theme.danger)
                        .textSelection(.enabled)
                        .padding(.top, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
