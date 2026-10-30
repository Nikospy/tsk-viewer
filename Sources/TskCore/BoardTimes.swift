import Foundation

public struct TaskTimes: Equatable, Sendable {
    public let created: Date
    public let updated: Date
    public init(created: Date, updated: Date) { self.created = created; self.updated = updated }
}

/// tsk 0.11.6 lists no dates, so they come read-only from the board file the CLI owns.
/// An unreadable or reshaped file only loses the dates; tasks still come from the CLI.
public enum BoardTimes {
    /// Where tsk keeps the board: TSK_STATE_DIR, else ~/.tsk.
    public static func storeURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let dir = environment["TSK_STATE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tsk")
        return dir.appendingPathComponent("tsk.json")
    }

    public static func read(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: TaskTimes] {
        guard let data = try? Data(contentsOf: storeURL(environment: environment)) else { return [:] }
        return parse(data)
    }

    /// Keyed like `TskTask.id`. tsk stores a moment as `[seconds, nanoseconds]`.
    public static func parse(_ data: Data) -> [String: TaskTimes] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tasks = root["tasks"] as? [[String: Any]] else { return [:] }
        var times: [String: TaskTimes] = [:]
        for task in tasks {
            guard let number = task["number"] as? Int, let created = moment(task["created_at"]) else { continue }
            times["T\(number)"] = TaskTimes(created: created, updated: moment(task["updated_at"]) ?? created)
        }
        return times
    }

    private static func moment(_ value: Any?) -> Date? {
        guard let parts = value as? [NSNumber], parts.count == 2 else { return nil }
        return Date(timeIntervalSince1970: parts[0].doubleValue + parts[1].doubleValue / 1_000_000_000)
    }

    /// Day, month and time; the year only when it is not the current one.
    public static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                             language: Language = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        if language == .pl {
            formatter.locale = Locale(identifier: "pl_PL")
            formatter.dateFormat = sameYear ? "d.MM HH:mm" : "d.MM.yyyy HH:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = sameYear ? "MMM d HH:mm" : "MMM d yyyy HH:mm"
        }
        return formatter.string(from: date)
    }
}
