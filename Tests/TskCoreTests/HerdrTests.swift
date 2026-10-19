import Foundation
import Testing
@testable import TskCore

private func screen(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures/screens"))
    return try String(contentsOf: url, encoding: .utf8)
}

private actor HerdrScript: CommandRunning {
    var replies: [([String], CommandOutput)]
    var calls: [[String]] = []
    init(_ replies: [([String], CommandOutput)]) { self.replies = replies }
    func run(executable: String, arguments: [String]) async throws -> CommandOutput {
        calls.append(arguments)
        guard !replies.isEmpty else { throw TskError.launch("Nieoczekiwana komenda: \(arguments)") }
        let (expected, output) = replies.removeFirst()
        #expect(arguments == expected)
        return output
    }
    func sent() -> [[String]] { calls }
}

private func agentJSON(pane: String = "w5Q:pS", terminal: String = "term_1", kind: String = "claude",
                       status: String = "idle", cwd: String = "/Users/admin/dev/active/caissa", session: String? = "s1") -> String {
    let sessionJSON = session.map { #"{"agent":"\#(kind)","kind":"id","value":"\#($0)"}"# } ?? "null"
    return #"{"pane_id":"\#(pane)","terminal_id":"\#(terminal)","agent":"\#(kind)","agent_status":"\#(status)","cwd":"\#(cwd)","foreground_cwd":null,"name":"rozkmina","agent_session":\#(sessionJSON),"future":1}"#
}

private let claude = HerdrAgent(paneID: "w5Q:pS", terminalID: "term_1", kind: "claude", status: .idle,
                                cwd: "/Users/admin/dev/active/caissa", name: "rozkmina", session: "s1")
private let get = ["agent", "get", "w5Q:pS"]
private let read = ["agent", "read", "w5Q:pS", "--source", "detection", "--lines", "15"]
private func client(_ script: HerdrScript) -> HerdrClient {
    HerdrClient(executablePath: "/herdr", environment: [:], runner: script)
}

@Test func parsesAgentListTolerantly() throws {
    let json = #"{"result":{"agents":[\#(agentJSON()),\#(agentJSON(pane: "w5S:p1", kind: "codex", status: "weird", session: nil)),{"pane_id":1}]}}"#
    let agents = try HerdrParse.agents(json)
    #expect(agents.count == 2)
    #expect(agents[0] == claude)
    #expect(agents[1].status == .unknown && agents[1].session == nil)
    #expect(throws: HerdrError.self) { try HerdrParse.agents(#"{"result":{}}"#) }
}

@Test(arguments: [
    ("claude", "claude-bez-dialogu"), ("claude", "claude-bez-dialogu-2"), ("claude", "claude-bez-dialogu-3"),
    ("claude", "claude-bez-dialogu-auto-podpowiedz"), ("claude", "claude-pracuje"), ("claude", "claude-ramka-z-tytulem"),
    ("codex", "codex-bez-dialogu"), ("codex", "codex-bez-dialogu-waski"), ("codex", "codex-pracuje"),
    ("omp", "omp-bez-dialogu"), ("grok", "grok-bez-dialogu"),
])
func plainInputBoxesAreReady(kind: String, name: String) throws {
    #expect(ScreenGuard.evaluate(kind: kind, screen: try screen(name)) == .ready)
}

@Test(arguments: [
    ("claude", "claude-akceptacja-planu-auto", "claude_akceptacja_planu"),
    ("claude", "claude-akceptacja-planu", "claude_wyjscie_z_planu"),
    ("claude", "claude-zaufanie-folderu", "claude_zaufanie_folderu"),
    ("codex", "codex-zaufanie-folderu", "codex_zaufanie_folderu"),
    ("codex", "codex-limit-tygodniowy", "codex_limit"),
])
func knownDialogsBlockTheSend(kind: String, name: String, dialog: String) throws {
    #expect(ScreenGuard.evaluate(kind: kind, screen: try screen(name)) == .dialog(dialog))
}

@Test func unknownScreensAndKindsAreNeverReady() throws {
    // Another agent's input box, a cut-off omp editor, a Grok box without its footer, an unknown kind.
    #expect(ScreenGuard.evaluate(kind: "grok", screen: try screen("claude-bez-dialogu")) == .unrecognized)
    let omp = try screen("omp-bez-dialogu").trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(ScreenGuard.evaluate(kind: "omp", screen: String(omp[..<omp.range(of: "╰─", options: .backwards)!.lowerBound])) == .unrecognized)
    let grok = try screen("grok-bez-dialogu").replacingOccurrences(of: "Shift+Tab:mode  │  Ctrl+.:shortcuts", with: "")
    #expect(ScreenGuard.evaluate(kind: "grok", screen: grok) == .unrecognized)
    #expect(ScreenGuard.evaluate(kind: "gemini", screen: try screen("claude-bez-dialogu")) == .unrecognized)
}

@Test func sendRevalidatesReadsScreenThenPrompts() async throws {
    let script = HerdrScript([
        (get, CommandOutput(exitCode: 0, stdout: #"{"result":{"agent":\#(agentJSON())}}"#)),
        (read, CommandOutput(exitCode: 0, stdout: try screen("claude-bez-dialogu"))),
        (["agent", "prompt", "w5Q:pS", "tsk: T4 gotowe"], CommandOutput(exitCode: 0)),
    ])
    #expect(await client(script).send("tsk: T4 gotowe", to: claude) == .delivered)
}

@Test func sendStopsBeforePromptWhenAnythingIsOff() async throws {
    // Same pane, new terminal: a different agent took the pane.
    let changed = HerdrScript([(get, CommandOutput(exitCode: 0, stdout: #"{"result":{"agent":\#(agentJSON(terminal: "term_2"))}}"#))])
    #expect(await client(changed).send("tsk", to: claude) == .agentChanged)

    let blocked = HerdrScript([(get, CommandOutput(exitCode: 0, stdout: #"{"result":{"agent":\#(agentJSON(status: "blocked"))}}"#))])
    #expect(await client(blocked).send("tsk", to: claude) == .agentBlocked)

    let gone = HerdrScript([(get, CommandOutput(exitCode: 1, stderr: #"{"error":{"code":"agent_not_found"}}"#))])
    #expect(await client(gone).send("tsk", to: claude) == .agentGone)

    // herdr says done, but the screen shows plan approval: Enter would approve it.
    let dialog = HerdrScript([
        (get, CommandOutput(exitCode: 0, stdout: #"{"result":{"agent":\#(agentJSON(status: "done"))}}"#)),
        (read, CommandOutput(exitCode: 0, stdout: try screen("claude-akceptacja-planu-auto"))),
    ])
    #expect(await client(dialog).send("tsk", to: claude) == .dialog("claude_akceptacja_planu"))

    let dash = HerdrScript([])
    #expect(await client(dash).send("-rf", to: claude) == .failed("invalid message or pane"))
    #expect(await dash.sent().isEmpty)

    let other = HerdrAgent(paneID: "w5Q:p9", terminalID: "t", kind: "gemini", status: .idle, cwd: "/")
    #expect(await client(HerdrScript([])).send("tsk", to: other) == .unsupported)
}

@Test func promptRefusalIsReported() async throws {
    let script = HerdrScript([
        (get, CommandOutput(exitCode: 0, stdout: #"{"result":{"agent":\#(agentJSON(status: "working"))}}"#)),
        (read, CommandOutput(exitCode: 0, stdout: try screen("claude-pracuje"))),
        (["agent", "prompt", "w5Q:pS", "tsk"], CommandOutput(exitCode: 1, stderr: #"{"error":{"code":"agent_blocked"}}"#)),
    ])
    #expect(await client(script).send("tsk", to: claude) == .agentBlocked)
}

@Test func messagesAreSingleLineAndPointAtTsk() {
    let task = TskTask(id: "T4", title: "Odświeżyć\ncaissa-state.md", project: "/x/caissa", status: .ready)
    #expect(AgentMessage.decision(.accept, task: task, language: .pl)
        == "tsk: T4 „Odświeżyć caissa-state.md” — gracz: zaakceptowane, status done. Szczegóły: tsk list T4 --json")
    #expect(AgentMessage.decision(.sendBack, task: task, language: .en)
        == "tsk: T4 “Odświeżyć caissa-state.md” — user: changes requested in notes (last Reply: line), status ready. Details: tsk list T4 --json")
    #expect(AgentMessage.decision(.reply, task: task, language: .pl).contains("(ostatnia linia Odp:)"))
    for language in Language.allCases {
        let many = AgentMessage.discussion([task, TskTask(id: "T5", title: "Poprawki", status: .ready)], language: language)
        #expect(!many.contains("\n") && many.hasPrefix("tsk: ") && many.contains("tsk list T5 --json"))
    }
}

@Test func languageFollowsSettingThenSystem() {
    #expect(Language.resolve(setting: "en", preferred: ["pl-PL"]) == .en)
    #expect(Language.resolve(setting: "system", preferred: ["pl-PL", "en-GB"]) == .pl)
    #expect(Language.resolve(setting: nil, preferred: ["de-DE", "pl-PL"]) == .en)
    #expect(Language.resolve(setting: nil, preferred: []) == .en)
}

@Test func projectAgentsComeFirst() throws {
    // The temporary directory sits behind the /var → /private/var symlink, like /tmp → /private/tmp.
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("tsk-viewer-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    for folder in ["caissa/sub", "cai", "inny"] {
        try FileManager.default.createDirectory(at: base.appendingPathComponent(folder), withIntermediateDirectories: true)
    }
    let real = PathMatch.resolved(base.path)
    #expect(real != base.path)
    let inProject = HerdrAgent(paneID: "w1:p1", terminalID: "a", kind: "claude", status: .working, cwd: real + "/caissa/sub")
    let idleElsewhere = HerdrAgent(paneID: "w1:p2", terminalID: "b", kind: "omp", status: .idle, cwd: real + "/inny")
    let split = AgentRanking.split([idleElsewhere, inProject], projects: [base.path + "/caissa", nil])
    #expect(split.matching == [inProject])
    #expect(split.others == [idleElsewhere])
    #expect(!PathMatch.inside(base.path + "/cai", real + "/caissa"))
}

@Test func senderIsTheLastValidSignatureInTheNotes() {
    let notes = """
    Herdr: w1:p1
    Which option?
    - A
    Herdr: w5Y:p3
    Odp: B
    Herdr: not-a-pane
    """
    #expect(AgentSender.pane(in: notes) == "w5Y:p3")
    #expect(AgentSender.pane(in: "no signature") == nil)
    #expect(AgentSender.isMarker("  Herdr: w2:p7 "))
    #expect(!AgentSender.isMarker("Herdr: wkrótce"))
}

@Test func renameNormalizesClearsAndRefusesInvalidNames() async {
    let agent = HerdrAgent(paneID: "w1:p2", terminalID: "t", kind: "claude", status: .idle, cwd: "/tmp")
    let script = HerdrScript([
        (["agent", "rename", "w1:p2", "code-reviewer"], CommandOutput(exitCode: 0, stdout: "")),
        (["agent", "rename", "w1:p2", "--clear"], CommandOutput(exitCode: 0, stdout: "")),
    ])
    let client = HerdrClient(executablePath: "/bin/herdr", runner: script)
    #expect(await client.rename(agent, to: " Code reviewer ") == nil)
    #expect(await client.rename(agent, to: "") == nil)
    #expect(await client.rename(agent, to: "--clear") != nil)
    #expect(await client.rename(agent, to: "żółw") != nil)
    #expect(await script.calls.count == 2)
}
