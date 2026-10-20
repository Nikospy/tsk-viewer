import Foundation

public enum TaskAction: String, CaseIterable, Sendable, Identifiable {
    case agree, reply, accept, sendBack, toDo, close
    public var id: Self { self }
    public var title: String {
        switch self {
        case .agree: L("Agree", pl: "Zgoda")
        case .reply: L("Reply", pl: "Odpowiedz")
        case .accept: L("Accept", pl: "Akceptuj")
        case .sendBack: L("Send back with notes", pl: "Odeślij z uwagami")
        case .toDo: L("To do", pl: "Do zrobienia")
        case .close: L("Close", pl: "Zamknij")
        }
    }
    public var requiresReply: Bool { self == .reply || self == .sendBack }
    /// Close archives the task and keeps its status, so it has no target status.
    public var targetStatus: WritableStatus? {
        switch self {
        case .accept: .done
        case .close: nil
        default: .ready
        }
    }
    /// Answers to an agent's question or hand-over; an open task has no agent and closing tells nobody.
    public var notifiesAgent: Bool { self != .toDo && self != .close }
    /// Actions that end the task's life on the board ask "sure?" first.
    public var needsSecondClick: Bool { self == .accept || self == .close }
    public static func available(for status: TskStatus) -> [TaskAction] {
        switch status {
        case .blocked: [.agree, .reply, .close]
        case .review: [.accept, .sendBack, .close]
        case .open: [.toDo, .close]
        case .ready, .started: [.close]
        default: []
        }
    }
}

public enum ReplyNotes {
    /// Original notes are preserved byte-for-byte; only the new reply is normalized.
    public static func appending(_ reply: String, to notes: String, language: Language = .current) throws -> String {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TskError.emptyReply }
        let line = language.replyPrefix + " " + trimmed.components(separatedBy: .newlines).joined(separator: " ")
        return notes + (notes.isEmpty || notes.hasSuffix("\n") ? "" : "\n") + line
    }
}

/// Opaque continuation issued only after a reply was confirmed saved. Retry never edits notes.
public struct StatusRetry: Equatable, Sendable {
    public let expectedTask: TskTask
    public let targetStatus: WritableStatus
    fileprivate init(expectedTask: TskTask, targetStatus: WritableStatus) {
        self.expectedTask = expectedTask; self.targetStatus = targetStatus
    }
}

public enum ActionOutcome: Equatable, Sendable {
    case completed
    case needsConfirmation
    case notWritten
    case replySavedStatusUnchanged
    case unverified
    case failed
    case busy
}

/// Keep the draft until completed; replace the displayed task whenever `task` is nonnil.
/// On needsConfirmation the caller must explicitly confirm again using the fresh full task.
/// If `retry` is present, confirmation MUST call retryStatus, not perform: the reply is already saved.
public struct ActionResult: Equatable, Sendable {
    public let outcome: ActionOutcome
    public let task: TskTask?
    public let retry: StatusRetry?
    public let message: String
    public let mutation: MutationResult?
}

/// Serializes mutations within this service, including across async suspension points.
/// This reduces races, not eliminates them: tsk has no compare-and-swap between read and write.
public actor TaskActionService {
    private let client: TskClient
    private var running = false
    public init(client: TskClient) { self.client = client }

    public func perform(_ action: TaskAction, on baseline: TskTask, reply: String = "") async -> ActionResult {
        guard !running else { return result(.busy, task: nil, message: busy) }
        running = true
        defer { running = false }
        guard TaskAction.available(for: baseline.status).contains(action) else {
            return result(.failed, task: baseline, message: TskError.invalidAction.localizedDescription)
        }
        var latest: TskTask? = baseline
        var mutated = false
        do {
            let expectedNotes = action.requiresReply ? try ReplyNotes.appending(reply, to: baseline.notes) : baseline.notes
            let fresh = try await current(baseline.id)
            latest = fresh
            guard matches(fresh, baseline) else { return conflict(fresh) }
            guard let target = action.targetStatus else { return await archive(expected: fresh) }
            if action.requiresReply {
                let edit = try await client.editNotes(baseline.id, notes: expectedNotes)
                switch edit {
                case .acknowledged, .indeterminate:
                    mutated = true
                    let confirmed = try await current(baseline.id)
                    latest = confirmed
                    if !sameNotes(confirmed.notes, expectedNotes) {
                        if sameNotes(confirmed.notes, baseline.notes) {
                            return result(.notWritten, task: confirmed, message: L("The reply was not saved. The text stays in the field.", pl: "Odpowiedź nie została zapisana. Tekst pozostaje w polu."), mutation: edit)
                        }
                        return conflict(confirmed, mutation: edit)
                    }
                    // An external status change after edit must not be overwritten.
                    guard confirmed.status == baseline.status else { return conflict(confirmed, mutation: edit) }
                    let retry = StatusRetry(expectedTask: confirmed, targetStatus: target)
                    return await changeStatus(expected: confirmed, target: target, retry: retry)
                default:
                    return result(.notWritten, task: fresh, message: edit.message ?? L("The reply was not saved.", pl: "Odpowiedź nie została zapisana."), mutation: edit)
                }
            }
            return await changeStatus(expected: fresh, target: target, retry: nil)
        } catch {
            return result(mutated ? .unverified : .failed, task: latest,
                          message: mutated ? L("Could not confirm the save. Refresh the task; do not resend the reply blindly.", pl: "Nie udało się potwierdzić zapisu. Odśwież zadanie; nie ponawiaj odpowiedzi w ciemno.") + " \(error.localizedDescription)" : error.localizedDescription)
        }
    }

    public func retryStatus(_ retry: StatusRetry) async -> ActionResult {
        guard !running else { return result(.busy, task: nil, message: busy) }
        running = true
        defer { running = false }
        return await changeStatus(expected: retry.expectedTask, target: retry.targetStatus, retry: retry)
    }

    private func changeStatus(expected: TskTask, target: WritableStatus, retry: StatusRetry?) async -> ActionResult {
        var latest = expected
        var attempted = false
        do {
            let fresh = try await current(expected.id)
            latest = fresh
            guard matches(fresh, expected) else { return conflict(fresh, retry: retry) }
            let mutation = try await client.setStatus(expected.id, status: target)
            attempted = true
            switch mutation {
            case .acknowledged, .indeterminate:
                let confirmed = try await current(expected.id)
                latest = confirmed
                if confirmed.status.rawValue == target.rawValue {
                    return result(.completed, task: confirmed, message: L("Saved.", pl: "Zapisano."), mutation: mutation)
                }
                guard confirmed.status == expected.status && sameNotes(confirmed.notes, expected.notes) else {
                    return conflict(confirmed, retry: retry, mutation: mutation)
                }
                return unchanged(confirmed, retry: retry, mutation: mutation)
            default:
                return unchanged(fresh, retry: retry, mutation: mutation)
            }
        } catch {
            if attempted {
                return result(.unverified, task: latest, message: L("Could not confirm the status. Refresh the task before the next action.", pl: "Nie udało się potwierdzić statusu. Odśwież zadanie przed kolejną akcją.") + " \(error.localizedDescription)")
            }
            return result(retry == nil ? .failed : .replySavedStatusUnchanged, task: latest, retry: retry,
                          message: retry == nil ? error.localizedDescription : replySavedStatusUnchanged + ". \(error.localizedDescription)")
        }
    }

    /// Archiving keeps status and notes, so it cannot overwrite an agent's change made after the fresh read.
    /// A direct lookup still finds archived tasks; only the archived list proves the close.
    /// `tsk archive` is idempotent, so an unconfirmed close is safe to repeat and needs no inspection.
    private func archive(expected: TskTask) async -> ActionResult {
        var attempted = false
        do {
            let mutation = try await client.archive(expected.id)
            attempted = true
            switch mutation {
            case .acknowledged, .indeterminate:
                if try await client.isArchived(expected.id) {
                    return result(.completed, task: expected, message: L("Closed.", pl: "Zamknięto."), mutation: mutation)
                }
                // Nothing was archived, so the fresh state needs a plain confirmation, not an inspection.
                let confirmed = try await current(expected.id)
                guard matches(confirmed, expected) else { return conflict(confirmed) }
                return result(.notWritten, task: confirmed, message: mutation.message ?? notClosed, mutation: mutation)
            default:
                return result(.notWritten, task: expected, message: mutation.message ?? notClosed, mutation: mutation)
            }
        } catch {
            return result(.failed, task: expected, message: attempted
                ? L("Could not confirm the close. Refresh the list; closing again is safe.", pl: "Nie udało się potwierdzić zamknięcia. Odśwież listę; ponowne zamknięcie jest bezpieczne.") + " \(error.localizedDescription)"
                : error.localizedDescription)
        }
    }
    private var notClosed: String { L("The task was not closed.", pl: "Zadanie nie zostało zamknięte.") }

    private func unchanged(_ task: TskTask, retry: StatusRetry?, mutation: MutationResult) -> ActionResult {
        result(retry == nil ? .notWritten : .replySavedStatusUnchanged, task: task, retry: retry,
               message: retry == nil ? (mutation.message ?? L("Status unchanged.", pl: "Status bez zmian.")) : replySavedStatusUnchanged, mutation: mutation)
    }
    private var busy: String { L("The task is being saved.", pl: "Trwa zapisywanie zadania.") }
    private var replySavedStatusUnchanged: String { L("Reply saved, status unchanged", pl: "Odpowiedź zapisana, status bez zmian") }
    private func current(_ id: String) async throws -> TskTask {
        if let task = try await client.fetch(id) { return task }
        if let task = try await client.fetch(id, includeDone: true) { return task }
        throw TskError.taskMissing(id)
    }
    private func matches(_ lhs: TskTask, _ rhs: TskTask) -> Bool {
        lhs.status == rhs.status && sameNotes(lhs.notes, rhs.notes)
    }
    private func sameNotes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    private func conflict(_ task: TskTask, retry: StatusRetry? = nil, mutation: MutationResult? = nil) -> ActionResult {
        // A fresh notes baseline is usable only after explicit confirmation, and only while
        // the original action's source status still holds. It never appends a second reply.
        let continuation = retry.flatMap {
            task.status == $0.expectedTask.status ? StatusRetry(expectedTask: task, targetStatus: $0.targetStatus) : nil
        }
        return result(.needsConfirmation, task: task, retry: continuation,
                      message: L("The task changed. Check the fresh state and confirm again. Your text was kept.", pl: "Zadanie zmieniło się. Sprawdź świeży stan i potwierdź ponownie. Wpisany tekst został zachowany."), mutation: mutation)
    }
    private func result(_ outcome: ActionOutcome, task: TskTask?, retry: StatusRetry? = nil, message: String, mutation: MutationResult? = nil) -> ActionResult {
        ActionResult(outcome: outcome, task: task, retry: retry, message: message, mutation: mutation)
    }
}
