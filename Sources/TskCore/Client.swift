import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }
}

/// Inject a deterministic executor for tests. Arguments never contain an executable or shell command.
public protocol CommandRunning: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CommandOutput
}

public enum TskError: Error, LocalizedError, Equatable, Sendable {
    case executableMissing(String)
    case launch(String)
    case command(exitCode: Int32, refusalCode: String?, message: String)
    case invalidJSON(String)
    case taskMissing(String)
    case emptyReply
    case invalidAction

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path): L("tsk not found: \(path). Check the path in settings.", pl: "Nie znaleziono programu tsk: \(path). Sprawdź ścieżkę w ustawieniach.")
        case .launch(let message): L("Cannot launch tsk: \(message)", pl: "Nie można uruchomić tsk: \(message)")
        case .command(let code, _, let message): L("tsk exited with code \(code): \(message)", pl: "tsk zakończył się kodem \(code): \(message)")
        case .invalidJSON(let message): L("Cannot read tsk data: \(message)", pl: "Nie można odczytać danych tsk: \(message)")
        case .taskMissing(let id): L("Task \(id) not found. Refresh the list.", pl: "Nie znaleziono zadania \(id). Odśwież listę.")
        case .emptyReply: L("Type a reply.", pl: "Wpisz treść odpowiedzi.")
        case .invalidAction: L("This action is not available for the current status.", pl: "Ta akcja nie jest dostępna dla bieżącego statusu.")
        }
    }
}

/// Process and both pipe readers run off the main actor; concurrent drains avoid pipe deadlocks.
public struct ProcessRunner: CommandRunning {
    public init() {}
    public func run(executable: String, arguments: [String]) async throws -> CommandOutput {
        try await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                throw TskError.executableMissing(executable)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { throw TskError.launch(error.localizedDescription) }
            async let stdout = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
            async let stderr = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }.value
            process.waitUntilExit()
            return await CommandOutput(exitCode: process.terminationStatus,
                                       stdout: String(decoding: stdout, as: UTF8.self),
                                       stderr: String(decoding: stderr, as: UTF8.self))
        }.value
    }
}

/// Only these destination statuses can be written by this application.
public enum WritableStatus: String, Sendable, Codable { case ready, done }

public enum MutationResult: Equatable, Sendable {
    case acknowledged
    case refused(code: String?, message: String)
    case invalidInvocation(code: String?, message: String)
    case indeterminate(message: String)
    case unexpected(exitCode: Int32, message: String)

    public var message: String? {
        switch self {
        case .acknowledged: nil
        case .refused(_, let message), .invalidInvocation(_, let message), .indeterminate(let message), .unexpected(_, let message): message
        }
    }
}

public struct TskClient: Sendable {
    public let executablePath: String
    private let runner: any CommandRunning

    /// Explicit app setting wins over TSK_PATH, then the Homebrew default.
    public init(executablePath: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
                runner: any CommandRunning = ProcessRunner()) {
        self.executablePath = executablePath ?? environment["TSK_PATH"] ?? "/opt/homebrew/bin/tsk"
        self.runner = runner
    }

    /// Summary rows may omit notes and steps. Fetch full detail before opening an action editor.
    public func listAll() async throws -> [TskTask] {
        try await read(["list", "--all", "--json"])
    }

    /// Direct lookups include done tasks in tsk 0.11.6. A done fallback must use a scoped list:
    /// tsk refuses combining a task operand with --done. Re-fetch the matching row for full notes.
    public func fetch(_ id: String, includeDone: Bool = false) async throws -> TskTask? {
        if includeDone {
            let rows = try await read(["list", "--all", "--done", "--json"])
            guard let row = rows.first(where: { $0.id == id }) else { return nil }
            return try await directFetch(row.id)
        }
        return try await directFetch(id)
    }

    private func directFetch(_ id: String) async throws -> TskTask? {
        let output = try await runner.run(executable: executablePath, arguments: ["list", id, "--json"])
        // A missing direct address is exit 2, not a mutation refusal. Other usage errors remain visible.
        let firstLine = output.stderr.split(whereSeparator: \.isNewline).first
        if output.exitCode == 2 && firstLine == "tsk list: unknown task" { return nil }
        try checkRead(output)
        return try decode(output.stdout).first(where: { $0.id == id })
    }

    public func setStatus(_ id: String, status: WritableStatus) async throws -> MutationResult {
        try await mutate(["status", id, status.rawValue])
    }
    public func editNotes(_ id: String, notes: String) async throws -> MutationResult {
        try await mutate(["edit", id, "--notes=\(notes)"])
    }
    /// Keeps the status; the task leaves every live list. Exit 0 also when it already was archived.
    public func archive(_ id: String) async throws -> MutationResult {
        try await mutate(["archive", id])
    }
    /// A direct lookup returns archived tasks like live ones, so only the archived list tells them apart.
    public func isArchived(_ id: String) async throws -> Bool {
        try await read(["list", "--all", "--archived", "--json"]).contains { $0.id == id }
    }

    private func read(_ arguments: [String]) async throws -> [TskTask] {
        let output = try await runner.run(executable: executablePath, arguments: arguments)
        try checkRead(output)
        return try decode(output.stdout)
    }
    private func decode(_ text: String) throws -> [TskTask] {
        do { return try JSONDecoder().decode([TskTask].self, from: Data(text.utf8)) }
        catch { throw TskError.invalidJSON(error.localizedDescription) }
    }
    private func checkRead(_ output: CommandOutput) throws {
        guard output.exitCode == 0 else {
            throw TskError.command(exitCode: output.exitCode, refusalCode: Self.refusalCode(output.stderr), message: output.stderr)
        }
    }
    private func mutate(_ arguments: [String]) async throws -> MutationResult {
        let output = try await runner.run(executable: executablePath, arguments: arguments)
        let code = Self.refusalCode(output.stderr)
        switch output.exitCode {
        case 0: return .acknowledged
        case 1: return .refused(code: code, message: output.stderr)
        case 2: return .invalidInvocation(code: code, message: output.stderr)
        case 3: return .indeterminate(message: output.stderr)
        default: return .unexpected(exitCode: output.exitCode, message: output.stderr)
        }
    }
    private static func refusalCode(_ stderr: String) -> String? {
        guard let first = stderr.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = first.split(separator: ":", omittingEmptySubsequences: false)
        let token = parts.count > 1 && parts[0].hasPrefix("tsk ") ? parts[1] : parts[0]
        let code = token.trimmingCharacters(in: .whitespaces)
        return code.isEmpty ? nil : code
    }
}
