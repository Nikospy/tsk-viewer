import Foundation

/// Unknown future statuses remain visible, but never acquire mutation actions.
public enum TskStatus: Hashable, Sendable, Codable {
    case open, ready, started, blocked, review, done
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "open": self = .open
        case "ready": self = .ready
        case "started": self = .started
        case "blocked": self = .blocked
        case "review": self = .review
        case "done": self = .done
        default: self = .unknown(rawValue)
        }
    }
    public var rawValue: String {
        switch self {
        case .open: "open"
        case .ready: "ready"
        case .started: "started"
        case .blocked: "blocked"
        case .review: "review"
        case .done: "done"
        case .unknown(let value): value
        }
    }
    public var needsAttention: Bool { self == .blocked || self == .review }
    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct TskStep: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let done: Bool

    public init(id: String, title: String, done: Bool = false) {
        self.id = id; self.title = title; self.done = done
    }
    private enum CodingKeys: String, CodingKey { case id, shortID = "short_id", title, text, done, completed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .shortID) ?? c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? c.decodeIfPresent(String.self, forKey: .text) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .shortID); try c.encode(title, forKey: .title); try c.encode(done, forKey: .done)
    }
}

/// `id` is the user-facing T number. A nil project denotes the desk.
public struct TskTask: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let project: String?
    public let status: TskStatus
    public let notes: String
    public let steps: [TskStep]
    /// tsk reports a project as its repository path; people know it by the folder name.
    public var projectName: String { project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("Desk", pl: "Biurko") }

    public init(id: String, title: String, project: String? = nil, status: TskStatus, notes: String = "", steps: [TskStep] = []) {
        self.id = id; self.title = title; self.project = project
        self.status = status; self.notes = notes; self.steps = steps
    }
    private enum CodingKeys: String, CodingKey { case id, shortID = "short_id", number, title, project, status, notes, steps }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let short = try c.decodeIfPresent(String.self, forKey: .shortID) {
            id = short
        } else if let number = try c.decodeIfPresent(Int.self, forKey: .number) {
            id = "T\(number)"
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        title = try c.decode(String.self, forKey: .title)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        status = try c.decode(TskStatus.self, forKey: .status)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        steps = try c.decodeIfPresent([TskStep].self, forKey: .steps) ?? []
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .shortID); try c.encode(title, forKey: .title)
        try c.encodeIfPresent(project, forKey: .project); try c.encode(status, forKey: .status)
        try c.encode(notes, forKey: .notes); try c.encode(steps, forKey: .steps)
    }
}

public struct TaskGroup: Identifiable, Equatable, Sendable {
    public let project: String?
    public let tasks: [TskTask]
    public var id: String { project.map { "project:\($0)" } ?? "desk:" }
    public var title: String { project.map { URL(fileURLWithPath: $0).lastPathComponent } ?? L("Desk", pl: "Biurko") }
}

public enum TaskGrouping {
    public static func attentionCount(_ tasks: [TskTask]) -> Int {
        tasks.lazy.filter { $0.status.needsAttention }.count
    }
    public static func groups(_ tasks: [TskTask], includeOtherStatuses: Bool = false) -> [TaskGroup] {
        let filtered = tasks.filter { $0.status != .done && (includeOtherStatuses || $0.status.needsAttention) }
        return Dictionary(grouping: filtered, by: \.project).map { TaskGroup(project: $0.key, tasks: $0.value.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
