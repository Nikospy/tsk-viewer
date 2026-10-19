import AppKit
import SwiftUI
import TskCore

@MainActor
final class ViewerModel: ObservableObject {
    struct Detail {
        var task: TskTask
        var reply = ""
        var action: TaskAction?
        var retry: StatusRetry?
        var message: String?
        var requiresInspection = false
    }

    @Published var tasks: [TskTask] = []
    @Published var selectedID: String?
    @Published var details: [String: Detail] = [:]
    @Published var includeOthers = false
    @Published var loading = false
    @Published var loadingDetail = false
    @Published var saving = false
    @Published var error: String?
    @Published var detailError: String?
    @Published var lastRefresh: Date?
    @Published var interval: Double
    @Published var executableSetting: String
    /// "system", "en" or "pl"; the panel is rebuilt when the resolved language changes.
    @Published var languageSetting: String
    @Published var language: Language
    /// Last state change the app made, shown as the command it ran.
    @Published var lastCommand: String?
    @Published var agents: [HerdrAgent] = []
    @Published var agentError: String?
    @Published var checked: Set<String> = []
    @Published var targetPane: String?
    @Published var dispatch: (text: String, ok: Bool)?
    @Published var sendingToAgent = false
    var notify: (([TaskTransition]) -> Void)?
    var closePanel: (() -> Void)?
    var openAgentNames: (() -> Void)?

    private var client: TskClient
    private var service: TaskActionService
    private var detector = TransitionDetector()
    private var polling: Task<Void, Never>?
    private let herdr = HerdrClient()

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: "pollInterval")
        interval = stored.isFinite && stored >= 2 ? min(stored, 3600) : 10
        let path = defaults.string(forKey: "tskExecutable") ?? ""
        executableSetting = path
        let setting = defaults.string(forKey: "language") ?? "system"
        languageSetting = setting
        Language.current = Language.resolve(setting: setting)
        language = Language.current
        let client = TskClient(executablePath: path.isEmpty ? nil : path)
        self.client = client
        service = TaskActionService(client: client)
    }

    var attentionCount: Int { TaskGrouping.attentionCount(tasks) }
    var groups: [TaskGroup] { TaskGrouping.groups(tasks, includeOtherStatuses: includeOthers) }
    var detail: Detail? { selectedID.flatMap { details[$0] } }
    var effectivePath: String { client.executablePath }

    func startPolling() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let seconds = self.interval
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            }
        }
    }

    func saveSettings(path: String, seconds: Double, language setting: String) {
        guard !saving, !loading, !loadingDetail else { return }
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = path != executableSetting
        executableSetting = path
        interval = seconds.isFinite ? min(max(seconds, 2), 3600) : 10
        UserDefaults.standard.set(path, forKey: "tskExecutable")
        UserDefaults.standard.set(interval, forKey: "pollInterval")
        UserDefaults.standard.set(setting, forKey: "language")
        languageSetting = setting
        Language.current = Language.resolve(setting: setting)
        language = Language.current
        if changed {
            client = TskClient(executablePath: path.isEmpty ? nil : path)
            service = TaskActionService(client: client)
            detector = TransitionDetector()
            tasks = []
            details = [:]
            selectedID = nil
        }
        startPolling()
    }

    func refresh() async {
        guard !loading, !saving else { return }
        loading = true
        defer { loading = false }
        do {
            let fresh = try await client.listAll()
            guard !Task.isCancelled else { return }
            tasks = fresh
            error = nil
            lastRefresh = Date()
            notify?(detector.consume(.success(fresh)))
        } catch {
            self.error = error.localizedDescription
            _ = detector.consume(.failure(error))
        }
        await refreshAgents()
    }

    // MARK: Agents

    private func refreshAgents() async {
        do {
            agents = try await herdr.agents()
            agentError = nil
        } catch {
            agents = []
            agentError = error.localizedDescription
        }
        checked.formIntersection(tasks.map(\.id))
        resolveTarget()
    }

    /// Tasks the agent strip acts on: the checked ones, else the open task.
    var dispatchTasks: [TskTask] {
        let picked = tasks.filter { checked.contains($0.id) }
        if !picked.isEmpty { return picked }
        return tasks.filter { $0.id == selectedID }
    }

    var agentSplit: (matching: [HerdrAgent], others: [HerdrAgent]) {
        AgentRanking.split(agents, projects: dispatchTasks.map(\.project))
    }

    var targetAgent: HerdrAgent? { agents.first { $0.paneID == targetPane } }

    private var contextKey: String { dispatchTasks.first?.project ?? "desk" }

    private var remembered: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "agentByProject") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "agentByProject") }
    }

    /// The pane that signed the tasks' notes; checked tasks from different agents have no single sender.
    var senderPane: String? {
        let panes = Set(dispatchTasks.compactMap { AgentSender.pane(in: details[$0.id]?.task.notes ?? $0.notes) })
        return panes.count == 1 ? panes.first : nil
    }

    var sender: HerdrAgent? { senderPane.flatMap { pane in agents.first { $0.paneID == pane } } }

    /// Picks made against the sender stay for these tasks only; polling would otherwise restore the sender.
    private var overrides: [String: String?] = [:]
    private var dispatchKey: String { dispatchTasks.map(\.id).sorted().joined(separator: ",") }

    func chooseAgent(_ pane: String?) {
        targetPane = pane
        if senderPane != nil { overrides[dispatchKey] = .some(pane) } else { remembered[contextKey] = pane }
    }

    /// The agent that asked, while it is still reachable; else the one last chosen for this project,
    /// else the only reachable agent working in it.
    func resolveTarget() {
        if let override = overrides[dispatchKey], override.map({ pane in agents.contains { $0.paneID == pane } }) ?? true {
            targetPane = override
            return
        }
        if let sender, sender.reachable {
            targetPane = sender.paneID
            return
        }
        if let pane = remembered[contextKey], agents.contains(where: { $0.paneID == pane }) {
            targetPane = pane
            return
        }
        let candidates = agentSplit.matching.filter(\.reachable)
        targetPane = candidates.count == 1 ? candidates[0].paneID : nil
    }

    func toggleCheck(_ id: String) {
        if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
        resolveTarget()
    }

    func clearChecks() {
        checked = []
        resolveTarget()
    }

    func agentLabel(_ agent: HerdrAgent) -> String {
        let status = switch agent.status {
        case .idle: L("idle", pl: "wolny")
        case .working: L("working", pl: "pracuje")
        case .done: L("finished", pl: "skończył")
        case .blocked: L("waiting for a decision", pl: "czeka na decyzję")
        case .unknown: L("unknown state", pl: "stan nieznany")
        }
        let asked = agent.paneID == senderPane ? L(" · asked", pl: " · pytał") : ""
        return "\(agent.name ?? agent.folder) · \(agent.kind) · \(status)\(asked)"
    }

    /// Saves every changed name at once; returns what went wrong per pane.
    func renameAgents(_ drafts: [String: String]) async -> [String: String] {
        let changes = agents.compactMap { agent -> (agent: HerdrAgent, name: String)? in
            guard let draft = drafts[agent.paneID] else { return nil }
            let name = AgentName.normalize(draft)
            return name == (agent.name ?? "") ? nil : (agent, name)
        }
        guard !changes.isEmpty else { return [:] }
        let problems = await herdr.rename(changes)
        lastCommand = "herdr agent rename … (\(changes.count))"
        await refreshAgents()
        return problems
    }

    func focusAgent(_ agent: HerdrAgent) async {
        await herdr.focus(agent)
    }

    /// Sends the checked tasks (or the open one) to the chosen agent for discussion; statuses stay as they are.
    func sendForDiscussion() async {
        let picked = dispatchTasks
        guard let agent = targetAgent, !picked.isEmpty, !sendingToAgent else { return }
        sendingToAgent = true
        defer { sendingToAgent = false }
        let result = await herdr.send(AgentMessage.discussion(picked), to: agent)
        report(result, to: agent, what: picked.map(\.id).joined(separator: ", "))
        if result == .delivered {
            lastCommand = "herdr agent prompt \(agent.paneID) …"
            clearChecks()
        }
    }

    private func notifyAgent(_ action: TaskAction, task: TskTask) async {
        guard let agent = targetAgent else { return }
        report(await herdr.send(AgentMessage.decision(action, task: task), to: agent), to: agent, what: task.id)
    }

    private func report(_ result: SendResult, to agent: HerdrAgent, what: String) {
        let name = agent.name ?? agent.folder
        dispatch = result == .delivered
            ? ("→ " + L("\(what) sent to \(name)", pl: "\(what) wysłane do \(name)") + " (\(agent.paneID))", true)
            : ("! \(name): \(result.message)", false)
    }

    func select(_ id: String, reload: Bool = false) async {
        guard !saving else { return }
        selectedID = id
        detailError = nil
        if checked.isEmpty { resolveTarget() }
        if details[id] != nil && !reload { return }
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            guard let task = try await client.fetch(id) else { throw TskError.taskMissing(id) }
            if var existing = details[id] {
                // Keep the editor's baseline until explicit confirmation detects a conflict.
                if existing.action == nil && existing.retry == nil && !existing.requiresInspection {
                    existing.task = task
                }
                details[id] = existing
            } else {
                details[id] = Detail(task: task)
            }
            // Full notes arrive only now, and with them the sender's signature.
            if checked.isEmpty && selectedID == id { resolveTarget() }
        } catch {
            detailError = error.localizedDescription
        }
    }

    func setReply(_ text: String) {
        guard let id = selectedID, !saving else { return }
        details[id]?.reply = text
    }

    func choose(_ action: TaskAction) {
        guard let id = selectedID, var detail = details[id], !saving,
              detail.retry == nil, !detail.requiresInspection else { return }
        if action.requiresReply {
            detail.action = action
            detail.message = nil
            details[id] = detail
        } else {
            Task { await perform(action, id: id) }
        }
    }

    func sendReply() async {
        guard let id = selectedID, let detail = details[id], let action = detail.action,
              !detail.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TaskAction.available(for: detail.task.status).contains(action),
              detail.retry == nil, !detail.requiresInspection else { return }
        await perform(action, id: id)
    }

    private func perform(_ action: TaskAction, id: String) async {
        guard !saving, let detail = details[id] else { return }
        saving = true
        let result = await service.perform(action, on: detail.task, reply: detail.reply)
        apply(result, id: id)
        if result.outcome == .completed {
            let status = "tsk status \(id) \(action.targetStatus.rawValue)"
            lastCommand = action.requiresReply ? "tsk edit \(id) --notes=… && \(status)" : status
            await notifyAgent(action, task: detail.task)
        }
        saving = false
        await refresh()
    }

    func retryStatus() async {
        guard !saving, let id = selectedID, let retry = details[id]?.retry else { return }
        saving = true
        let result = await service.retryStatus(retry)
        apply(result, id: id)
        if result.outcome == .completed { lastCommand = "tsk status \(id) \(retry.targetStatus.rawValue)" }
        saving = false
        await refresh()
    }

    private func apply(_ result: ActionResult, id: String) {
        guard var detail = details[id] else { return }
        if let task = result.task { detail.task = task }
        detail.retry = result.retry
        detail.message = result.message
        // A confirmed/possibly saved edit without a continuation cannot safely be replayed.
        detail.requiresInspection = result.outcome == .unverified ||
            (result.outcome == .needsConfirmation && result.mutation != nil && result.retry == nil)
        if result.outcome == .completed {
            detail.reply = ""
            detail.action = nil
        }
        details[id] = detail
    }

    func closeEditor() {
        guard let id = selectedID, !saving else { return }
        details[id]?.action = nil
        // Never discard text merely because the editor is closed.
    }

    func acknowledgeInspection() async {
        guard let id = selectedID, !saving else { return }
        // Explicit user acknowledgement, not an automatic mutation retry.
        loadingDetail = true
        defer { loadingDetail = false }
        do {
            guard let fresh = try await client.fetch(id) else { throw TskError.taskMissing(id) }
            details[id]?.task = fresh
            details[id]?.requiresInspection = false
            details[id]?.action = nil
            details[id]?.message = L("State read. Check the kept text before starting a new reply.", pl: "Stan odczytany. Zachowany tekst sprawdź przed rozpoczęciem nowej odpowiedzi.")
            detailError = nil
        } catch { detailError = error.localizedDescription }
    }
}
