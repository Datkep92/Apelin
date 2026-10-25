import CoreFoundation
import Foundation

/// Where the `<system-state>` block's facts come from: the device's
/// language and region settings and its clock. The worker reads them
/// itself, as the mobile user it runs as, so a message another
/// conversation sends gets them too; tests hand in their own.
public struct SystemStateSource: Sendable {
    /// The preferred languages, most preferred first, as BCP 47 tags.
    public var languages: @Sendable () -> [String]
    /// The region, an ISO 3166 code such as `CN`; nil when unset.
    public var region: @Sendable () -> String?
    public var now: @Sendable () -> Date
    public var timeZone: @Sendable () -> TimeZone

    public init(
        languages: @escaping @Sendable () -> [String],
        region: @escaping @Sendable () -> String?,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: @escaping @Sendable () -> TimeZone = SystemStateSource.systemTimeZone,
    ) {
        self.languages = languages
        self.region = region
        self.now = now
        self.timeZone = timeZone
    }

    /// The device's zone as it is now: Foundation keeps the one it read
    /// first, and a worker outlives a flight.
    public static let systemTimeZone: @Sendable () -> TimeZone = {
        NSTimeZone.resetSystemTimeZone()
        return TimeZone.current
    }

    /// The device's global preferences: `AppleLanguages` and `AppleLocale`
    /// of the user the process runs as, read again each time (Settings
    /// changes them while a worker runs), else what Foundation has.
    public static let device = preferences { key in
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost,
        )
    }

    /// Facts read through `value`, a reader of the global preferences.
    public static func preferences(_ value: @escaping @Sendable (String) -> Any?) -> SystemStateSource {
        SystemStateSource(
            languages: {
                let languages = (value("AppleLanguages") as? [String]) ?? []
                return languages.isEmpty ? Locale.preferredLanguages : languages
            },
            region: {
                SystemState.region(locale: value("AppleLocale") as? String)
                    ?? SystemState.region(language: (value("AppleLanguages") as? [String])?.first)
            },
        )
    }
}

/// What the model reads before every message the user, or another
/// conversation, sends (`AgentSession.prompt` and `steer`): the system
/// language and the reply rule, the local time and the approval mode on
/// now. Like `<project-context>` it is added to the text the model sees,
/// never to the event the app shows, and it stays in that message of the
/// transcript, so every later request sends the same bytes. What changes
/// while a session runs lives here and nowhere in the system prompt, which
/// is the session's snapshot (`PromptState`) and whose cache it would break.
///
/// The language, the time and the mode are in every block: about sixty
/// tokens, paid in full once and read from the cache after. Saying only
/// what changed would save some forty a message, but the time changes on
/// every one anyway, and a compaction that summarises the message that
/// last named the language or the mode would leave the model guessing.
/// What the system prompt shows — instructions, skills, memory, the
/// environment — is said only when it changed, once, as a delta.
enum SystemState {
    static let openingTag = "<system-state>"
    static let closingTag = "</system-state>"
    /// How many preferred languages are named.
    static let maximumLanguages = 3

    struct Facts {
        var languages: [String]
        var region: String?
        var date: Date
        var timeZone: TimeZone
        var mode: ApprovalMode
        /// What changed since the model was last told (`PromptState`).
        var changes: [String] = []
    }

    static func facts(_ source: SystemStateSource, mode: ApprovalMode, changes: [String] = []) -> Facts {
        Facts(
            languages: source.languages(),
            region: source.region(),
            date: source.now(),
            timeZone: source.timeZone(),
            mode: mode,
            changes: changes,
        )
    }

    /// The block, ending with a blank line, to put before the message.
    static func make(_ facts: Facts) -> String {
        let languages = facts.languages.compactMap(tag).prefix(maximumLanguages)
        let language = languages.first.map(name) ?? "not known"
        var system = "- System language: \(language)"
        if !languages.isEmpty {
            system += "; preferred: " + languages.joined(separator: ", ")
        }
        if let region = facts.region.flatMap(regionCode) {
            system += "; region \(region)"
        }
        let reply = languages.isEmpty
            ? "- Reply in the language the user writes in."
            : "- Reply in the language the user writes in; when that is unclear, in \(language)."
        var lines = [
            openingTag,
            "Apelin's note on this message, not the user's words; they do not see it.",
            system + ".",
            reply,
            "- Local time: \(time(facts.date, in: facts.timeZone)).",
            "- Approval mode: \(modeName(facts.mode)).",
        ]
        if !facts.changes.isEmpty {
            lines.append("- Changed since you were last told; the system prompt still shows the earlier state:")
            // an entry's later lines indented under it
            lines += facts.changes.map { "  - " + $0.replacingOccurrences(of: "\n", with: "\n    ") }
        }
        lines.append(closingTag)
        return lines.joined(separator: "\n") + "\n\n"
    }

    static func modeName(_ mode: ApprovalMode) -> String {
        switch mode {
        case .relaxed: "Relaxed"
        case .confirm: "Strict"
        case .full: "Full"
        }
    }

    /// `Saturday 2026-10-24 23:58, Asia/Shanghai (UTC+08:00)`.
    static func time(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        let offset = zone.secondsFromGMT(for: date) / 60
        let sign = offset < 0 ? "-" : "+"
        let utc = String(format: "UTC%@%02d:%02d", sign, abs(offset) / 60, abs(offset) % 60)
        return "\(formatter.string(from: date)), \(zone.identifier) (\(utc))"
    }

    /// `zh-Hans-CN` as English names it: `Chinese (Simplified, China mainland)`.
    private static func name(_ tag: String) -> String {
        Locale(identifier: "en_US_POSIX").localizedString(forIdentifier: tag) ?? tag
    }

    /// A language tag as the preferences hold it, or nil for anything that
    /// is not one: they are a file the user can write.
    private static func tag(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !value.isEmpty, value.count <= 35, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return value.replacingOccurrences(of: "_", with: "-")
    }

    private static func regionCode(_ value: String) -> String? {
        let code = value.uppercased()
        guard (2 ... 3).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return code
    }

    /// The region of `AppleLocale` (`zh_CN`, `en_GB@calendar=…`).
    static func region(locale: String?) -> String? {
        guard let locale else { return nil }
        let base = locale.split(separator: "@").first.map(String.init) ?? locale
        let parts = base.split(whereSeparator: { $0 == "_" || $0 == "-" })
        guard parts.count >= 2, let last = parts.last else { return nil }
        return regionCode(String(last))
    }

    /// The region subtag of a language tag (`zh-Hans-CN` → `CN`).
    static func region(language: String?) -> String? {
        guard let language else { return nil }
        let parts = language.split(whereSeparator: { $0 == "_" || $0 == "-" }).dropFirst()
        return parts.last { $0.count == 2 || ($0.count == 3 && $0.allSatisfy(\.isNumber)) }.flatMap { regionCode(String($0)) }
    }
}
