import Foundation

/// A configuration named through `+` whose key has not been saved yet.
///
/// `agentAccountList` lists what the keychain holds, and takes a
/// configuration's name out of the credential itself, so a configuration that
/// has just been named has neither a row nor a name to show: nothing would say
/// it exists until the key was typed in, and a page left half-read would leave
/// nothing behind at all. This keeps that name in a device preference, keyed
/// by the configuration's id, until the listing has the id — at which point the
/// row, and the name, are the listing's own, and this forgets it. Signing out
/// puts the name back, since that is a key given up rather than a
/// configuration, and a swipe is how the configuration goes.
///
/// Nothing secret is kept here: a name, and the id the keychain will be asked
/// for under, which already states the provider.
enum PendingConfigurations {
    private static let key = "pendingConfigurations"

    /// One named configuration, and nothing else about it.
    private struct Entry: Codable, Equatable {
        var id: String
        var name: String
    }

    /// The named configurations still waiting for a key, oldest first.
    static func waiting() -> [(id: String, name: String)] {
        entries().map { ($0.id, $0.name) }
    }

    static func contains(_ id: String) -> Bool {
        entries().contains { $0.id == id }
    }

    /// Keeps the latest name for `id`, at the end: a name changed through `+`
    /// again is one configuration, not two.
    static func save(_ name: String, for id: String) {
        write(entries().filter { $0.id != id } + [Entry(id: id, name: name)])
    }

    static func remove(_ id: String) {
        write(entries().filter { $0.id != id })
    }

    /// Forget every configuration the listing now carries: its credential
    /// holds a name of its own, so this one has nothing left to add.
    static func prune(listed ids: Set<String>) {
        write(entries().filter { !ids.contains($0.id) })
    }

    private static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private static func write(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}