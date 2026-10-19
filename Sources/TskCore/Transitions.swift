import Foundation

public struct TaskTransition: Equatable, Sendable, Identifiable {
    public let task: TskTask
    public var id: String { task.id }
    public var title: String { "\(task.id) · \(task.title)" }
    public var project: String { task.projectName }
    public var status: TskStatus { task.status }
}

/// Feed only polling results, not detail reads. Failure leaves the last successful snapshot intact.
public struct TransitionDetector: Sendable {
    private var previous: [String: TskStatus]?
    public init() {}
    public mutating func consume(_ result: Result<[TskTask], any Error>) -> [TaskTransition] {
        guard case .success(let tasks) = result else { return [] }
        var next: [String: TskStatus] = [:]
        var events: [TaskTransition] = []
        for task in tasks {
            if let previous, task.status.needsAttention, previous[task.id] != task.status, next[task.id] == nil {
                events.append(TaskTransition(task: task))
            }
            next[task.id] = task.status
        }
        previous = next
        return events
    }
}
