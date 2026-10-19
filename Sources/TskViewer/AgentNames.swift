import AppKit
import SwiftUI
import TskCore

/// Every Herdr agent with its name in one place; one save renames them all.
struct AgentNamesView: View {
    @ObservedObject var model: ViewerModel
    let close: () -> Void
    @State private var drafts: [String: String] = [:]
    @State private var failures: [String: String] = [:]
    @State private var saving = false
    /// A ScrollView has no height of its own in a window sized to its content, so it takes the rows' height.
    @State private var rowsHeight: CGFloat = 0

    private var agents: [HerdrAgent] {
        model.agents.sorted { ($0.folder, $0.paneID) < ($1.folder, $1.paneID) }
    }

    private func draft(_ agent: HerdrAgent) -> String { drafts[agent.paneID] ?? agent.name ?? "" }

    private func changed(_ agent: HerdrAgent) -> Bool {
        drafts[agent.paneID].map { AgentName.normalize($0) != (agent.name ?? "") } ?? false
    }

    /// Checked across all agents, so a draft cannot take a name another agent keeps.
    private var problems: [String: String] {
        AgentName.problems(Dictionary(agents.map { ($0.paneID, draft($0)) }, uniquingKeysWith: { $1 }))
    }

    private var changes: Int { agents.filter(changed).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("tsk").font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                Text("~").foregroundStyle(Theme.faint)
                Text(L("name agents", pl: "nazwij agentów")).font(Theme.mono(13, .semibold))
                Text("[\(agents.count)]").foregroundStyle(Theme.faint)
            }
            Text(L("lowercase letters, digits, - and _ · an empty field removes the name · agents also name themselves",
                   pl: "małe litery, cyfry, - i _ · puste pole usuwa nazwę · agenci nadają sobie nazwy także sami"))
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                .padding(.top, 6).padding(.bottom, 16)

            if agents.isEmpty {
                Text(model.agentError ?? L("Herdr reports no agents.", pl: "Herdr nie zgłasza żadnego agenta."))
                    .foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(agents) { row($0) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .scrollIndicators(.never)
                .frame(height: min(rowsHeight, 420))
            }

            HStack(spacing: 8) {
                Button(L("suggest empty", pl: "podpowiedz puste")) {
                    let current = Dictionary(agents.map { ($0.paneID, draft($0)) }, uniquingKeysWith: { $1 })
                    for (pane, name) in AgentName.suggest(agents, drafts: current) where current[pane] != name {
                        drafts[pane] = name
                    }
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(!agents.contains { draft($0).isEmpty })
                .help(L("Fills empty names with the folder name; you can still edit them before saving.",
                        pl: "Wpisuje w puste pola nazwę folderu; przed zapisem możesz je jeszcze poprawić."))
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(L("cancel", pl: "anuluj"), action: close)
                    .buttonStyle(GhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(changes == 0 ? L("save", pl: "zapisz") : L("save (\(changes))", pl: "zapisz (\(changes))")) {
                    Task { await save() }
                }
                .buttonStyle(SolidButtonStyle(fill: Theme.accent, hoverFill: Theme.accentHover, foreground: Theme.accentText))
                .keyboardShortcut(.defaultAction)
                .disabled(saving || changes == 0 || !problems.isEmpty)
            }
            .padding(.top, 18)
        }
        .font(Theme.mono(13))
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 24)
        .frame(width: 680)
        .background(Theme.panel)
        .environment(\.colorScheme, .dark)
        .focusEffectDisabled()
    }

    private func row(_ agent: HerdrAgent) -> some View {
        let problem = failures[agent.paneID] ?? problems[agent.paneID]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 14) {
                TextField("", text: Binding(get: { draft(agent) }, set: { drafts[agent.paneID] = $0; failures[agent.paneID] = nil }),
                          prompt: Text(L("no name", pl: "bez nazwy")).foregroundColor(Theme.faint))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(13))
                    .padding(.horizontal, 10).frame(width: 220, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(problem != nil ? Theme.danger : changed(agent) ? Theme.accent : Theme.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(agent.kind) · \(agent.folder) · \(status(agent))").foregroundStyle(Theme.dim)
                    Text(agent.title.map { "„\($0)”" } ?? agent.paneID)
                        .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                }
                .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Button(L("show", pl: "pokaż")) { Task { await model.focusAgent(agent) } }
                    .buttonStyle(GhostButtonStyle())
                    .help(L("Brings this agent's pane to the front in Herdr (\(agent.paneID)).",
                            pl: "Przełącza Herdr na panel tego agenta (\(agent.paneID))."))
            }
            if let problem {
                Text(problem).font(Theme.mono(11)).foregroundStyle(Theme.danger).padding(.leading, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private func status(_ agent: HerdrAgent) -> String {
        switch agent.status {
        case .idle: L("idle", pl: "wolny")
        case .working: L("working", pl: "pracuje")
        case .done: L("finished", pl: "skończył")
        case .blocked: L("waiting for a decision", pl: "czeka na decyzję")
        case .unknown: L("unknown state", pl: "stan nieznany")
        }
    }

    /// Saved names leave the drafts; failures stay in their fields with the reason, and the window stays open.
    private func save() async {
        saving = true
        defer { saving = false }
        let result = await model.renameAgents(Dictionary(agents.filter(changed).map { ($0.paneID, draft($0)) }, uniquingKeysWith: { $1 }))
        failures = result
        drafts = drafts.filter { result[$0.key] != nil }
        if result.isEmpty { close() }
    }
}
