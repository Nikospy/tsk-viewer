import Foundation

// Ported from comment-annotate-mode (src/host/agenci.ts, dialogi.ts); see context/foundation/herdr-agents.md.

public enum AgentStatus: String, Sendable {
    case idle, working, blocked, done, unknown
}

/// (pane, terminal, session) must still match right before a prompt is sent.
public struct AgentIdentity: Equatable, Hashable, Sendable {
    public let paneID: String
    public let terminalID: String
    public let session: String?
}

public struct HerdrAgent: Equatable, Sendable, Identifiable {
    public let paneID: String
    public let terminalID: String
    public let kind: String
    public let status: AgentStatus
    public let cwd: String
    public let foregroundCwd: String?
    public let name: String?
    public let session: String?

    public var id: String { paneID }
    public var identity: AgentIdentity { AgentIdentity(paneID: paneID, terminalID: terminalID, session: session) }
    /// The foreground process directory is where the agent really works; the pane cwd is the fallback.
    public var directory: String { foregroundCwd ?? cwd }
    public var folder: String { URL(fileURLWithPath: directory).lastPathComponent }
    public var supported: Bool { ScreenGuard.supportedKinds.contains(kind) }
    /// herdr itself refuses blocked agents; unknown status is never trusted.
    public var reachable: Bool { supported && (status == .idle || status == .working || status == .done) }

    public init(paneID: String, terminalID: String, kind: String, status: AgentStatus, cwd: String,
                foregroundCwd: String? = nil, name: String? = nil, session: String? = nil) {
        self.paneID = paneID; self.terminalID = terminalID; self.kind = kind; self.status = status
        self.cwd = cwd; self.foregroundCwd = foregroundCwd; self.name = name; self.session = session
    }

    init?(json: Any?) {
        guard let row = json as? [String: Any],
              let pane = row["pane_id"] as? String, let terminal = row["terminal_id"] as? String,
              let kind = row["agent"] as? String, let cwd = row["cwd"] as? String else { return nil }
        let session = (row["agent_session"] as? [String: Any])?["value"] as? String
        self.init(paneID: pane, terminalID: terminal, kind: kind,
                  status: AgentStatus(rawValue: row["agent_status"] as? String ?? "") ?? .unknown,
                  cwd: cwd, foregroundCwd: row["foreground_cwd"] as? String,
                  name: (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }, session: session)
    }
}

public enum HerdrParse {
    public static func agents(_ stdout: String) throws -> [HerdrAgent] {
        let root = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        guard let rows = (root?["result"] as? [String: Any])?["agents"] as? [Any] else {
            throw HerdrError.unexpected(L("herdr agent list: unexpected response shape", pl: "herdr agent list: nieoczekiwany kształt odpowiedzi"))
        }
        return rows.compactMap { HerdrAgent(json: $0) }
    }

    public static func agent(_ stdout: String) -> HerdrAgent? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else { return nil }
        return HerdrAgent(json: (root["result"] as? [String: Any])?["agent"])
    }

    /// herdr reports failures as `{"error":{"code":…}}` on stderr.
    public static func errorCode(_ stderr: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(stderr.utf8)) as? [String: Any] else { return nil }
        return (root["error"] as? [String: Any])?["code"] as? String
    }
}

public enum HerdrError: Error, LocalizedError, Equatable, Sendable {
    case missing(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let path): L("herdr not found: \(path)", pl: "Nie znaleziono programu herdr: \(path)")
        case .unexpected(let message): message
        }
    }
}

public enum PathMatch {
    /// Compare only resolved paths (/tmp vs /private/tmp).
    public static func inside(_ project: String, _ path: String) -> Bool {
        let root = resolved(project), candidate = resolved(path)
        return candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func resolved(_ path: String) -> String {
        guard let real = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(real) }
        return String(cString: real)
    }
}

// MARK: - Screen guard

public enum ScreenVerdict: Equatable, Sendable {
    case ready
    case dialog(String)
    case unrecognized
}

/// herdr 0.9.3 reports some decision dialogs as done/idle, and the Enter from `agent prompt` then picks
/// the default option. A prompt goes out only when the bottom of the screen is the agent's plain input box.
public enum ScreenGuard {
    public static let supportedKinds: Set<String> = ["claude", "codex", "omp", "grok"]

    static let dialogs: [(name: String, pattern: String)] = [
        ("claude_akceptacja_planu", #"Would you like to proceed\?"#),
        ("claude_wyjscie_z_planu", #"Exit plan mode\?"#),
        ("claude_zaufanie_folderu", #"Quick safety check: Is this a project you created"#),
        ("codex_zaufanie_folderu", #"Trust this folder\? Codex"#),
        ("codex_limit", #"Approaching rate limits"#),
    ]

    public static func evaluate(kind: String, screen: String) -> ScreenVerdict {
        // Terminals wrap lines anywhere, so dialogs are matched on whitespace-collapsed text.
        let flat = screen.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if let dialog = dialogs.first(where: { flat.range(of: $0.pattern, options: .regularExpression) != nil }) {
            return .dialog(dialog.name)
        }
        var trimmed = screen
        while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
        let lines = trimmed.components(separatedBy: "\n")
        let plain: Bool
        switch kind {
        case "claude": plain = claudeInput(lines)
        case "codex": plain = codexInput(lines)
        case "omp": plain = ompInput(lines)
        case "grok": plain = grokInput(lines)
        default: plain = false
        }
        return plain ? .ready : .unrecognized
    }

    private static func matches(_ line: String, _ pattern: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    /// `❯` line right under the last-but-one `─` rule (which may carry a session title), status bar below.
    private static func claudeInput(_ lines: [String]) -> Bool {
        let rules = lines.indices.filter { matches(lines[$0], #"^─{20,}(?: .+ ─+)?\s*$"#) }
        guard rules.count >= 2 else { return false }
        let top = rules[rules.count - 2], bottom = rules[rules.count - 1]
        return bottom - top >= 2 && bottom - top <= 12 && lines[top + 1].hasPrefix("❯") && lines.count - bottom <= 6
    }

    /// Last `› ` field without numbered options, followed by Codex's footer.
    private static func codexInput(_ lines: [String]) -> Bool {
        guard let index = lines.lastIndex(where: { matches($0, #"^\s*› "#) }),
              matches(lines[index], #"^› "#), !matches(lines[index], #"^› \d+[.)](?:\s|$)"#) else { return false }
        return lines[(index + 1)...].contains { line in
            matches(line, #"← for agents|\? for shortcuts"#) ||
                matches(line, #"^\s+GPT-[\w.-]+(?:\s+[\w-]+)*\s+·\s+~/"#) ||
                matches(line, #"^\s+.*⚠\s+\d+\s+warnings\b"#)
        }
    }

    /// omp: editor framed by a model/context rule (`… ─── 53.9%/500K`) and a closing `╰─` as the last line.
    private static func ompInput(_ lines: [String]) -> Bool {
        guard let last = lines.last, matches(last, #"^╰─\s*$"#) else { return false }
        let bottom = lines.count - 1
        guard let top = lines[..<bottom].lastIndex(where: { matches($0, #"─{10,}.*\d+(?:\.\d+)?%/\d+[KM]"#) }) else { return false }
        return bottom - top >= 1 && bottom - top <= 10
    }

    /// Grok: last `╭─╮` box whose first line is `│ ❯`, closed by a `╰─ … Grok … ╯` rule, then the shortcut footer.
    private static func grokInput(_ lines: [String]) -> Bool {
        guard let bottom = lines.lastIndex(where: { matches($0, #"^\s*╰─.*Grok.*╯\s*$"#) }),
              let top = lines[..<bottom].lastIndex(where: { matches($0, #"^\s*╭─{10,}╮\s*$"#) }),
              bottom - top >= 2, bottom - top <= 12, matches(lines[top + 1], #"^\s*│ ❯"#) else { return false }
        return lines[(bottom + 1)...].contains { matches($0, #"Shift\+Tab:mode|Ctrl\+\.:shortcuts"#) }
    }
}

// MARK: - Client

public enum SendResult: Equatable, Sendable {
    case delivered
    case agentGone
    case agentChanged
    case agentBlocked
    case unsupported
    case dialog(String)
    case unrecognizedScreen
    case failed(String)

    public var message: String {
        switch self {
        case .delivered: L("sent", pl: "wysłano")
        case .agentGone: L("the agent is no longer in this pane", pl: "agenta już nie ma w tym panelu")
        case .agentChanged: L("a different agent runs in this pane now", pl: "w panelu działa teraz inny agent")
        case .agentBlocked: L("the agent is waiting for a decision — answer it in Herdr first", pl: "agent czeka na decyzję — najpierw odpowiedz mu w Herdr")
        case .unsupported: L("this kind of agent is not supported", pl: "ten rodzaj agenta nie jest obsługiwany")
        case .dialog: L("a decision dialog is on the agent's screen — not sent", pl: "na ekranie agenta jest okno decyzji — nie wysłano")
        case .unrecognizedScreen: L("the agent's screen does not look like its plain input box — not sent", pl: "ekran agenta nie wygląda na zwykłe pole wpisywania — nie wysłano")
        case .failed(let message): message
        }
    }
}

public struct HerdrClient: Sendable {
    public let executablePath: String
    private let runner: CommandRunning

    public init(executablePath: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                runner: CommandRunning = ProcessRunner()) {
        self.runner = runner
        if let executablePath, !executablePath.isEmpty {
            self.executablePath = executablePath
        } else if let fromEnvironment = environment["HERDR_PATH"], !fromEnvironment.isEmpty {
            self.executablePath = fromEnvironment
        } else {
            // A menu bar app has no ~/.local/bin in PATH.
            self.executablePath = NSHomeDirectory() + "/.local/bin/herdr"
        }
    }

    public func agents() async throws -> [HerdrAgent] {
        let output = try await run(["agent", "list"])
        guard output.exitCode == 0 else {
            throw HerdrError.unexpected("herdr agent list: \(HerdrParse.errorCode(output.stderr) ?? L("code", pl: "kod") + " \(output.exitCode)")")
        }
        return try HerdrParse.agents(output.stdout)
    }

    /// Re-validates the agent and its screen, then sends one prompt; herdr presses Enter itself.
    public func send(_ text: String, to expected: HerdrAgent) async -> SendResult {
        guard expected.supported else { return .unsupported }
        guard !text.hasPrefix("-"), !text.isEmpty,
              expected.paneID.range(of: #"^w[0-9A-Za-z]+:p[0-9A-Za-z]+$"#, options: .regularExpression) != nil else {
            return .failed(L("invalid message or pane", pl: "nieprawidłowa wiadomość albo panel"))
        }
        do {
            let current = try await run(["agent", "get", expected.paneID])
            if current.exitCode != 0 {
                return HerdrParse.errorCode(current.stderr) == "agent_not_found" ? .agentGone
                    : .failed("herdr agent get: \(HerdrParse.errorCode(current.stderr) ?? L("code", pl: "kod") + " \(current.exitCode)")")
            }
            guard let agent = HerdrParse.agent(current.stdout) else { return .agentGone }
            guard agent.identity == expected.identity, agent.kind == expected.kind else { return .agentChanged }
            if agent.status == .blocked { return .agentBlocked }
            guard agent.reachable else { return .failed(L("unknown agent state", pl: "nieznany stan agenta")) }

            let screen = try await run(["agent", "read", expected.paneID, "--source", "detection", "--lines", "15"])
            guard screen.exitCode == 0 else { return .failed(L("cannot read the agent's screen", pl: "nie można odczytać ekranu agenta")) }
            switch ScreenGuard.evaluate(kind: agent.kind, screen: screen.stdout) {
            case .ready: break
            case .dialog(let name): return .dialog(name)
            case .unrecognized: return .unrecognizedScreen
            }

            let prompt = try await run(["agent", "prompt", expected.paneID, text])
            if prompt.exitCode == 0 { return .delivered }
            switch HerdrParse.errorCode(prompt.stderr) {
            case "agent_blocked": return .agentBlocked
            case "agent_not_found": return .agentGone
            case let code: return .failed("herdr agent prompt: \(code ?? L("code", pl: "kod") + " \(prompt.exitCode)")")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// An empty name clears it, so the folder shows again. herdr accepts `[a-z][a-z0-9_-]{0,31}`; spaces become dashes.
    public func rename(_ agent: HerdrAgent, to name: String) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
        let invalid = L("a name is lowercase letters, digits, - or _ (up to 32), starting with a letter",
                        pl: "nazwa to małe litery bez polskich znaków, cyfry, - albo _ (do 32), na początku litera")
        guard name.isEmpty || name.range(of: #"^[a-z][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil else { return invalid }
        do {
            let output = try await run(["agent", "rename", agent.paneID] + (name.isEmpty ? ["--clear"] : [name]))
            if output.exitCode == 0 { return nil }
            let code = HerdrParse.errorCode(output.stderr)
            if code == "invalid_agent_name" { return invalid }
            return "herdr agent rename: \(code ?? L("code", pl: "kod") + " \(output.exitCode)")"
        } catch {
            return error.localizedDescription
        }
    }

    private func run(_ arguments: [String]) async throws -> CommandOutput {
        do {
            return try await runner.run(executable: executablePath, arguments: arguments)
        } catch TskError.executableMissing(let path) {
            throw HerdrError.missing(path)
        }
    }
}

// MARK: - Messages

/// One-line prompts: a newline would submit early, and the agent reads the details from tsk itself.
public enum AgentMessage {
    /// Agents are told how to react to these in their instructions, so the wording is a contract per language.
    public static func decision(_ action: TaskAction, task: TskTask, language: Language = .current) -> String {
        let prefix = language.replyPrefix
        switch language {
        case .pl:
            let verdict = switch action {
            case .agree: "zgoda, status ready"
            case .accept: "zaakceptowane, status done"
            case .reply: "odpowiedź dopisana do notatek (ostatnia linia \(prefix)), status ready"
            case .sendBack: "uwagi do poprawki w notatkach (ostatnia linia \(prefix)), status ready"
            }
            return "tsk: \(task.id) „\(oneLine(task.title))” — gracz: \(verdict). Szczegóły: tsk list \(task.id) --json"
        case .en:
            let verdict = switch action {
            case .agree: "approved, status ready"
            case .accept: "accepted, status done"
            case .reply: "reply added to notes (last \(prefix) line), status ready"
            case .sendBack: "changes requested in notes (last \(prefix) line), status ready"
            }
            return "tsk: \(task.id) “\(oneLine(task.title))” — user: \(verdict). Details: tsk list \(task.id) --json"
        }
    }

    public static func discussion(_ tasks: [TskTask], language: Language = .current) -> String {
        let reads = tasks.map { "tsk list \($0.id) --json" }.joined(separator: "; ")
        switch language {
        case .pl:
            let list = tasks.map { "\($0.id) „\(oneLine($0.title))”" }.joined(separator: ", ")
            let noun = tasks.count == 1 ? "zadanie" : "zadania"
            return "tsk: gracz prosi o omówienie i realizację: \(list). Przeczytaj \(noun) (\(reads)) i zaproponuj plan, zanim zaczniesz."
        case .en:
            let list = tasks.map { "\($0.id) “\(oneLine($0.title))”" }.joined(separator: ", ")
            let noun = tasks.count == 1 ? "the task" : "the tasks"
            return "tsk: user asks to discuss and carry out: \(list). Read \(noun) (\(reads)) and propose a plan before you start."
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}

/// Agents sign the notes with `Herdr: $HERDR_PANE_ID` when they hand a task to the user, so a reply goes back to them.
public enum AgentSender {
    static let prefix = "Herdr:"

    public static func isMarker(_ line: String) -> Bool {
        pane(line) != nil
    }

    /// The last signature wins: whoever asked most recently is waiting for the answer.
    public static func pane(in notes: String) -> String? {
        notes.components(separatedBy: .newlines).last { pane($0) != nil }.flatMap { pane($0) }
    }

    private static func pane(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return value.range(of: #"^w[0-9A-Za-z]+:p[0-9A-Za-z]+$"#, options: .regularExpression) != nil ? value : nil
    }
}

public enum AgentRanking {
    /// Agents working inside any of the tasks' projects first; desk tasks have no natural agent.
    public static func split(_ agents: [HerdrAgent], projects: [String?]) -> (matching: [HerdrAgent], others: [HerdrAgent]) {
        let roots = projects.compactMap { $0 }
        let order: (HerdrAgent) -> Int = { agent in
            switch agent.status {
            case .idle, .done: 0
            case .working: 1
            case .unknown: 2
            case .blocked: 3
            }
        }
        let sorted = agents.sorted { (order($0), $0.folder, $0.paneID) < (order($1), $1.folder, $1.paneID) }
        let matching = sorted.filter { agent in roots.contains { PathMatch.inside($0, agent.directory) } }
        return (matching, sorted.filter { agent in !matching.contains(agent) })
    }
}
