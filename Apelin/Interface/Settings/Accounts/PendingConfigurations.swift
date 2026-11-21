import ApelinProtocol
import Foundation

/// The configurations the reader named in Settings, kept until — and after —
/// their keys are saved.
///
/// `agentAccountList` takes a configuration's name out of its credential. A
/// configuration just named, or whose last key was signed out, has no
/// credential at all: nothing would say it exists. This keeps its name and
/// address in a device preference under an id no keychain profile can have, so
/// an unfinished sign-in and the loss of every key both leave the configuration
/// in place. The same record is what lets a rename reach every key of a group
/// without signing in again. A name first saved by an older build has no
/// address; it still reads here and is listed as waiting for its key.
///
/// Nothing secret is kept here: a name, an address and a provider.
enum PendingConfigurations {
    private static let key = "pendingConfigurations"
    private static let prefix = "config."

    /// One named configuration, and nothing else about it.
    private struct Entry: Codable, Equatable {
        var id: String
        var name: String
        /// The canonical Base URL of the group, absent on a name saved by an
        /// earlier build before configurations carried an address.
        var baseURL: String?
    }

    /// The identity of a configuration's name record. No real keychain
    /// profile id starts with `config.`, so a pending key is never mistaken for
    /// the definition of a group.
    static func storageID(provider: AgentProvider, baseURL: String) -> String {
        "\(prefix)\(provider.rawValue)|\(baseURL)"
    }

    /// The group a record belongs to, read back from its id.
    static func configuration(fromStorageID id: String) -> (provider: AgentProvider, baseURL: String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = AgentProvider(rawValue: String(parts[0])),
              !parts[1].isEmpty
        else { return nil }
        return (provider, String(parts[1]))
    }

    /// Every configuration kept by name, oldest first.
    static func configurations() -> [(id: String, name: String, baseURL: String?)] {
        entries().map { ($0.id, $0.name, $0.baseURL) }
    }

    /// The name kept for `id`: a group's name lives here too, so renaming it
    /// reaches every key in the group without signing in again.
    static func name(for id: String) -> String? {
        entries().first { $0.id == id }?.name
    }

    static func contains(_ id: String) -> Bool {
        entries().contains { $0.id == id }
    }

    /// Keeps the latest name and address for `id`, at the end: naming the same
    /// group again is one configuration, not two.
    static func save(_ name: String, baseURL: String? = nil, for id: String) {
        write(entries().filter { $0.id != id } + [Entry(id: id, name: name, baseURL: baseURL)])
    }

    static func remove(_ id: String) {
        write(entries().filter { $0.id != id })
    }

    /// Forget a name whose keychain profile now names itself. Definitions of
    /// groups are kept: a key has no say over the name the reader gave the
    /// group, and an empty configuration must outlive its last key.
    static func prune(listed ids: Set<String>) {
        write(entries().filter { $0.id.hasPrefix(prefix) || !ids.contains($0.id) })
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
