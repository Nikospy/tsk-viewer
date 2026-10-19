import Foundation
import Synchronization

/// Interface language. It also picks the agent contract: the reply prefix in notes and the `tsk:` messages.
public enum Language: String, CaseIterable, Sendable {
    case en, pl

    private static let storage = Mutex<Language>(.en)

    /// Set once from the app setting; tests and library callers get English unless they pass a language.
    public static var current: Language {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// An explicit setting wins; otherwise Polish only when it is the first preferred system language.
    public static func resolve(setting: String?, preferred: [String] = Locale.preferredLanguages) -> Language {
        if let setting, let language = Language(rawValue: setting) { return language }
        return preferred.first?.lowercased().hasPrefix("pl") == true ? .pl : .en
    }

    /// The prefix the user's answer gets in task notes.
    public var replyPrefix: String { self == .pl ? "Odp:" : "Reply:" }
}

/// English text with its Polish translation, picked by `Language.current`.
public func L(_ en: String, pl: String) -> String {
    Language.current == .pl ? pl : en
}
