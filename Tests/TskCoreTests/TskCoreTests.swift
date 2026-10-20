import Foundation
import Testing
@testable import TskCore

private func task(_ status: TskStatus = .blocked, notes: String = "agent", id: String = "T12") -> TskTask {
    TskTask(id: id, title: "Sprawdź wynik", project: "Projekt", status: status, notes: notes)
}
private func read(_ task: TskTask?) -> CommandOutput {
    CommandOutput(exitCode: 0, stdout: String(decoding: try! JSONEncoder().encode(task.map { [$0] } ?? []), as: UTF8.self))
}
private struct Exchange: Sendable {
    let arguments: [String]
    let output: CommandOutput
    init(_ arguments: [String], _ output: CommandOutput) { self.arguments = arguments; self.output = output }
}
private actor Script: CommandRunning {
    var exchanges: [Exchange]
    var calls: [[String]] = []
    init(_ exchanges: [Exchange]) { self.exchanges = exchanges }
    func run(executable: String, arguments: [String]) async throws -> CommandOutput {
        calls.append(arguments)
        guard !exchanges.isEmpty else { throw TskError.launch("Nieoczekiwana komenda: \(arguments)") }
        let next = exchanges.removeFirst()
        #expect(arguments == next.arguments)
        return next.output
    }
    func exhausted() -> Bool { exchanges.isEmpty }
}
private let fetch = ["list", "T12", "--json"]
private let edit = ["edit", "T12", "--notes=agent\nReply: Tak"]
private let ready = ["status", "T12", "ready"]
private let ok = CommandOutput(exitCode: 0)
private func service(_ script: Script) -> TaskActionService {
    TaskActionService(client: TskClient(environment: [:], runner: script))
}

@Test func actionMatrix() {
    #expect(TaskAction.available(for: .blocked) == [.agree, .reply, .close])
    #expect(TaskAction.available(for: .review) == [.accept, .sendBack, .close])
    #expect(TaskAction.available(for: .open) == [.toDo, .close])
    #expect(TaskAction.available(for: .ready) == [.close])
    #expect(TaskAction.available(for: .started) == [.close])
    for status in [TskStatus.done, .unknown("future")] {
        #expect(TaskAction.available(for: status).isEmpty)
    }
    #expect(TaskAction.accept.targetStatus == .done)
    #expect(TaskAction.sendBack.targetStatus == .ready)
    #expect(TaskAction.toDo.targetStatus == .ready)
    #expect(TaskAction.close.targetStatus == nil)
    #expect(TaskAction.allCases.filter(\.notifiesAgent) == [.agree, .reply, .accept, .sendBack])
    #expect(TaskAction.allCases.filter(\.needsSecondClick) == [.accept, .close])
}

@Test func repliesPreserveOriginalBytes() throws {
    #expect(try ReplyNotes.appending("  Tak  ", to: "") == "Reply: Tak")
    #expect(try ReplyNotes.appending("Tak", to: "agent") == "agent\nReply: Tak")
    #expect(try ReplyNotes.appending("Tak", to: "agent\n\n") == "agent\n\nReply: Tak")
    #expect(try ReplyNotes.appending("a\nb\rc\u{2028}d", to: "") == "Reply: a b c d")
    #expect(try ReplyNotes.appending("Tak", to: "agent", language: .pl) == "agent\nOdp: Tak")
    let original = "e\u{301}\t\r\n"
    #expect(try ReplyNotes.appending("-tak", to: original).utf8.starts(with: original.utf8))
    #expect(throws: TskError.emptyReply) { try ReplyNotes.appending(" \n\t", to: "") }
}

@Test func decodeRealCLIShapeAndUnknownFields() throws {
    let json = #"[{"id":"uuid","number":12,"title":"Praca","status":"future","project":null,"notes":null,"steps":[{"short_id":"s1","text":"Test","done":true,"future":7}],"future":{}}]"#
    let value = try JSONDecoder().decode([TskTask].self, from: Data(json.utf8))[0]
    #expect(value.id == "T12")
    #expect(value.projectName == "Desk")
    #expect(value.status == .unknown("future"))
    #expect(value.notes == "")
    #expect(value.steps == [TskStep(id: "s1", title: "Test", done: true)])
}

@Test func replyBeforeStatusAndVerifiedState() async {
    let saved = task(notes: "agent\nReply: Tak")
    let final = TskTask(id: "T12", title: "Świeży tytuł", status: .ready, notes: saved.notes)
    let script = Script([
        Exchange(fetch, read(task())), Exchange(edit, ok), Exchange(fetch, read(saved)),
        Exchange(fetch, read(saved)), Exchange(ready, ok), Exchange(fetch, read(final))
    ])
    let result = await service(script).perform(.reply, on: task(), reply: "Tak")
    #expect(result.outcome == .completed)
    #expect(result.task == final)
    #expect(await script.exhausted())
}

@Test func dashLeadingNotesAreSingleArgument() async throws {
    let script = Script([Exchange(["edit", "T12", "--notes=-5\nReply: -tak"], ok)])
    let client = TskClient(environment: [:], runner: script)
    let value = try ReplyNotes.appending("-tak", to: "-5")
    #expect(try await client.editNotes("T12", notes: value) == .acknowledged)
    #expect(await script.exhausted())
}

@Test(arguments: [task(notes: "zmienione"), task(.review), task(notes: "age\u{301}nt")])
func conflictNeverWrites(fresh: TskTask) async {
    let script = Script([Exchange(fetch, read(fresh))])
    let result = await service(script).perform(.reply, on: task(), reply: "Tak")
    #expect(result.outcome == .needsConfirmation)
    #expect(result.task == fresh)
    #expect(await script.calls.count == 1)
}

@Test func byteDistinctCanonicalNotesConflict() async {
    let baseline = task(notes: "é")
    let fresh = task(notes: "e\u{301}")
    let script = Script([Exchange(fetch, read(fresh))])
    #expect(await service(script).perform(.agree, on: baseline).outcome == .needsConfirmation)
    #expect(await script.calls.count == 1)
}

@Test(arguments: [task(notes: "Nowe dane agenta"), task(.review, notes: "agent\nReply: Tak")])
func statusGuardAfterSavedReplyNeverOverwritesConcurrentChanges(fresh: TskTask) async {
    let saved = task(notes: "agent\nReply: Tak")
    let script = Script([Exchange(fetch, read(task())), Exchange(edit, ok), Exchange(fetch, read(saved)), Exchange(fetch, read(fresh))])
    let result = await service(script).perform(.reply, on: task(), reply: "Tak")
    #expect(result.outcome == .needsConfirmation)
    #expect(result.task == fresh)
    #expect(await script.calls.count == 4)
}

@Test(arguments: [Int32(1), 2])
func editRefusalDoesNotChangeStatus(code: Int32) async {
    let failure = CommandOutput(exitCode: code, stderr: "tsk edit: invalid-title: odmowa\nsecond: ignored")
    let script = Script([Exchange(fetch, read(task())), Exchange(edit, failure)])
    let result = await service(script).perform(.reply, on: task(), reply: "Tak")
    #expect(result.outcome == .notWritten)
    #expect(result.retry == nil)
    if code == 1 { #expect(result.mutation == .refused(code: "invalid-title", message: failure.stderr)) }
    else { #expect(result.mutation == .invalidInvocation(code: "invalid-title", message: failure.stderr)) }
    #expect(await script.calls.count == 2)
}

@Test func partialSuccessRetriesOnlyStatus() async throws {
    let saved = task(notes: "agent\nReply: Tak")
    let script = Script([
        Exchange(fetch, read(task())), Exchange(edit, ok), Exchange(fetch, read(saved)), Exchange(fetch, read(saved)),
        Exchange(ready, CommandOutput(exitCode: 1, stderr: "tsk status: unknown-task: odmowa")),
        Exchange(fetch, read(saved)), Exchange(ready, ok), Exchange(fetch, read(task(.ready, notes: saved.notes)))
    ])
    let actions = service(script)
    let partial = await actions.perform(.reply, on: task(), reply: "Tak")
    #expect(partial.outcome == .replySavedStatusUnchanged)
    #expect(partial.message == "Reply saved, status unchanged")
    let retry = try #require(partial.retry)
    let final = await actions.retryStatus(retry)
    #expect(final.outcome == .completed)
    #expect(await script.calls.filter { $0.first == "edit" }.count == 1)
    #expect(await script.exhausted())
}

@Test(arguments: ["saved", "original", "other"])
func indeterminateEditClassifications(kind: String) async {
    let saved = task(notes: "agent\nReply: Tak")
    let observed = kind == "saved" ? saved : (kind == "original" ? task() : task(notes: "Inne"))
    var exchanges = [Exchange(fetch, read(task())), Exchange(edit, CommandOutput(exitCode: 3)), Exchange(fetch, read(observed))]
    if kind == "saved" {
        exchanges += [Exchange(fetch, read(saved)), Exchange(ready, ok), Exchange(fetch, read(task(.ready, notes: saved.notes)))]
    }
    let script = Script(exchanges)
    let result = await service(script).perform(.reply, on: task(), reply: "Tak")
    #expect(result.outcome == (kind == "saved" ? .completed : kind == "original" ? .notWritten : .needsConfirmation))
    #expect(result.task == (kind == "saved" ? task(.ready, notes: saved.notes) : observed))
    #expect(await script.exhausted())
}

@Test(arguments: [TskStatus.done, .review, .ready])
func indeterminateStatusClassifications(observedStatus: TskStatus) async {
    let baseline = task(.review)
    let observed = task(observedStatus)
    let script = Script([Exchange(fetch, read(baseline)), Exchange(fetch, read(baseline)),
                         Exchange(["status", "T12", "done"], CommandOutput(exitCode: 3)), Exchange(fetch, read(observed))])
    let result = await service(script).perform(.accept, on: baseline)
    #expect(result.outcome == (observedStatus == .done ? .completed : observedStatus == .review ? .notWritten : .needsConfirmation))
    #expect(result.task == observed)
    #expect(await script.exhausted())
}

@Test func statusZeroStillRequiresObservedTarget() async {
    let script = Script([Exchange(fetch, read(task())), Exchange(fetch, read(task())), Exchange(ready, ok), Exchange(fetch, read(task(.review)))])
    let result = await service(script).perform(.agree, on: task())
    #expect(result.outcome == .needsConfirmation)
    #expect(result.task?.status == .review)
}

@Test func completedFallbackUsesValidDoneScopeAndFullDetail() async {
    let baseline = task(.review)
    let done = task(.done)
    let script = Script([
        Exchange(fetch, read(baseline)), Exchange(fetch, read(baseline)), Exchange(["status", "T12", "done"], CommandOutput(exitCode: 3)),
        Exchange(fetch, read(nil)), Exchange(["list", "--all", "--done", "--json"], read(done)), Exchange(fetch, read(done))
    ])
    let result = await service(script).perform(.accept, on: baseline)
    #expect(result.outcome == .completed)
    #expect(result.task == done)
    #expect(await script.exhausted())
}

@Test func failedConfirmationNeverBlindlyRetries() async {
    let script = Script([Exchange(fetch, read(task())), Exchange(edit, ok), Exchange(fetch, CommandOutput(exitCode: 3, stderr: "read failed"))])
    let result = await service(script).perform(.reply, on: task(), reply: "Tak")
    #expect(result.outcome == .unverified)
    #expect(result.retry == nil)
    #expect(await script.calls.count == 3)
}

@Test func transitionsIgnoreFailedPollsAndFirstSuccess() {
    var detector = TransitionDetector()
    #expect(detector.consume(.failure(TskError.launch("offline"))).isEmpty)
    #expect(detector.consume(.success([task()])).isEmpty)
    #expect(detector.consume(.success([task()])).isEmpty)
    #expect(detector.consume(.failure(TskError.launch("offline"))).isEmpty)
    #expect(detector.consume(.success([task()])).isEmpty)
    let events = detector.consume(.success([task(.review), task(id: "T13")]))
    #expect(events.map(\.task.id) == ["T12", "T13"])
    #expect(events.first?.project == "Projekt")
    #expect(events.first?.status == .review)
    #expect(detector.consume(.success([task(.review), task(id: "T13")])).isEmpty)
    #expect(detector.consume(.success([task(.ready)])).isEmpty)
    #expect(detector.consume(.success([task()])).map(\.task.id) == ["T12"])
}

@Test func attentionGroupsExcludeReadOnlyStatusesAndDone() {
    let tasks = [task(), task(.review, id: "T13"), task(.started, id: "T14"), task(.done, id: "T15"),
                 TskTask(id: "T16", title: "Biurko", status: .blocked)]
    #expect(TaskGrouping.attentionCount(tasks) == 3)
    #expect(Set(TaskGrouping.groups(tasks).flatMap(\.tasks).map(\.id)) == ["T12", "T13", "T16"])
    #expect(Set(TaskGrouping.groups(tasks, includeOtherStatuses: true).flatMap(\.tasks).map(\.id)) == ["T12", "T13", "T14", "T16"])
}

@Test func missingTaskIsNotConfusedWithUsageError() async throws {
    let script = Script([
        Exchange(fetch, CommandOutput(exitCode: 2, stderr: "tsk list: unknown task\nusage: tsk list")),
        Exchange(fetch, CommandOutput(exitCode: 2, stderr: "tsk list: invalid argument\nusage: tsk list"))
    ])
    let client = TskClient(environment: [:], runner: script)
    #expect(try await client.fetch("T12") == nil)
    do {
        _ = try await client.fetch("T12")
        Issue.record("Usage error was hidden")
    } catch let error as TskError {
        #expect(error == .command(exitCode: 2, refusalCode: "invalid argument", message: "tsk list: invalid argument\nusage: tsk list"))
    }
}

@Test func retryRefusesNewerNotesWithoutDuplicatingReply() async throws {
    let saved = task(notes: "agent\nReply: Tak")
    let changed = task(notes: "agent\nReply: Tak\nNowa notatka")
    let script = Script([
        Exchange(fetch, read(task())), Exchange(edit, ok), Exchange(fetch, read(saved)),
        Exchange(fetch, read(saved)), Exchange(ready, CommandOutput(exitCode: 2)),
        Exchange(fetch, read(changed)), Exchange(fetch, read(changed)), Exchange(ready, ok),
        Exchange(fetch, read(task(.ready, notes: changed.notes)))
    ])
    let actions = service(script)
    let partial = await actions.perform(.reply, on: task(), reply: "Tak")
    let retry = try #require(partial.retry)
    let result = await actions.retryStatus(retry)
    #expect(result.outcome == .needsConfirmation)
    #expect(result.task == changed)
    let confirmedRetry = try #require(result.retry)
    #expect(confirmedRetry.expectedTask == changed)
    #expect(await script.calls.filter { $0.first == "edit" }.count == 1)
    #expect(await script.calls.filter { $0.first == "status" }.count == 1)
    let final = await actions.retryStatus(confirmedRetry)
    #expect(final.outcome == .completed)
    #expect(final.task?.notes == changed.notes)
    #expect(await script.calls.filter { $0.first == "edit" }.count == 1)
    #expect(await script.exhausted())
}

private let archive = ["archive", "T12"]
private let archived = ["list", "--all", "--archived", "--json"]

@Test(arguments: [TskStatus.open, .ready, .started, .blocked, .review])
func closeArchivesAndConfirmsInArchivedList(status: TskStatus) async {
    let script = Script([Exchange(fetch, read(task(status))), Exchange(archive, ok), Exchange(archived, read(task(status)))])
    let result = await service(script).perform(.close, on: task(status))
    #expect(result.outcome == .completed)
    #expect(result.task == task(status))
    #expect(await script.calls.allSatisfy { $0.first != "status" && $0.first != "edit" })
    #expect(await script.exhausted())
}

@Test(arguments: [task(notes: "zmienione"), task(.review)])
func closeOfChangedTaskNeverArchives(fresh: TskTask) async {
    let script = Script([Exchange(fetch, read(fresh))])
    let result = await service(script).perform(.close, on: task())
    #expect(result.outcome == .needsConfirmation)
    #expect(result.task == fresh)
    #expect(await script.calls.count == 1)
}

@Test func closeRefusalIsReported() async {
    let refusal = CommandOutput(exitCode: 1, stderr: "tsk archive: unknown-task: T12 is not on the board")
    let script = Script([Exchange(fetch, read(task())), Exchange(archive, refusal)])
    let result = await service(script).perform(.close, on: task())
    #expect(result.outcome == .notWritten)
    #expect(result.mutation == .refused(code: "unknown-task", message: refusal.stderr))
    #expect(result.message == refusal.stderr)
    #expect(await script.exhausted())
}

@Test func closeAcknowledgedButNotArchivedIsNotCompleted() async {
    let script = Script([Exchange(fetch, read(task())), Exchange(archive, ok), Exchange(archived, read(nil)), Exchange(fetch, read(task()))])
    let result = await service(script).perform(.close, on: task())
    #expect(result.outcome == .notWritten)
    #expect(result.message == "The task was not closed.")
    #expect(await script.exhausted())
}

@Test func closeUnknownOutcomeIsVerifiedNotRepeated() async {
    let script = Script([Exchange(fetch, read(task())), Exchange(archive, CommandOutput(exitCode: 3)), Exchange(archived, read(task()))])
    #expect(await service(script).perform(.close, on: task()).outcome == .completed)
    #expect(await script.calls.filter { $0.first == "archive" }.count == 1)
    #expect(await script.exhausted())
}

@Test func closeConcurrentChangeAfterNoOpAsksAgain() async {
    let changed = task(.review)
    let script = Script([Exchange(fetch, read(task())), Exchange(archive, ok), Exchange(archived, read(nil)), Exchange(fetch, read(changed))])
    let result = await service(script).perform(.close, on: task())
    #expect(result.outcome == .needsConfirmation)
    #expect(result.task == changed)
    // Nothing was archived, so the viewer asks for a plain confirmation rather than an inspection.
    #expect(result.mutation == nil)
}

@Test func closeOfDoneTaskIsRefusedLocally() async {
    let script = Script([])
    let result = await service(script).perform(.close, on: task(.done))
    #expect(result.outcome == .failed)
    #expect(await script.calls.isEmpty)
}

@Test func toDoMovesOpenTaskToReady() async {
    let script = Script([Exchange(fetch, read(task(.open))), Exchange(fetch, read(task(.open))),
                         Exchange(ready, ok), Exchange(fetch, read(task(.ready)))])
    let result = await service(script).perform(.toDo, on: task(.open))
    #expect(result.outcome == .completed)
    #expect(result.task?.status == .ready)
    #expect(await script.exhausted())
}

@Test func toDoOfPickedUpTaskNeverWrites() async {
    let script = Script([Exchange(fetch, read(task(.started)))])
    #expect(await service(script).perform(.toDo, on: task(.open)).outcome == .needsConfirmation)
    #expect(await script.calls.count == 1)
}
