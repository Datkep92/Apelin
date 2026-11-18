import ApelinProtocol
import Foundation

/// Tracks per-model health for the Model Health Check feature.
///
/// Each model (identified by `ComposerModelSelection.retryKey`) has a status:
/// - `.healthy` — last probe succeeded (HTTP 2xx)
/// - `.unhealthy` — last probe failed (connection error, timeout, HTTP 4xx/5xx)
/// - `.probing` — probe in progress
///
/// Results survive app restarts (UserDefaults JSON).
final class ModelHealth: @unchecked Sendable {
    static let shared = ModelHealth()

    private let defaults = UserDefaults.standard
    private let storageKey = "wiki.qaq.apelin.modelHealth"
    private let lock = NSLock()

    /// Cache: key = retryKey, value = record
    private var cache: [String: Record] = [:]
    private var isDirty = false

    private init() { load() }

    // MARK: - Public API

    /// Shared key for a (provider, profileID, model) triple.
    static func makeRetryKey(provider: AgentProvider, profileID: String?, model: String) -> String {
        "\(provider.rawValue)|\(profileID ?? "")|\(model)"
    }

    /// Save a single probe result.
    func mark(healthy: Bool, retryKey: String, error: String?) {
        if healthy {
            markHealthy(retryKey)
        } else {
            markUnhealthy(retryKey, error: error)
        }
    }

    /// Current status of a model. nil = never probed.
    func status(for retryKey: String) -> ModelHealthStatus? {
        lock.lock()
        defer { lock.unlock() }
        return cache[retryKey]?.status
    }

    /// Whether a model is excluded from automatic fallback lists.
    func isExcluded(_ retryKey: String) -> Bool {
        guard let s = status(for: retryKey) else { return false }
        if case .unhealthy = s { return true }
        return false
    }

    /// Mark a model as currently being probed.
    func markProbing(_ retryKey: String) {
        set(.probing, for: retryKey)
    }

    /// Mark healthy and save.
    func markHealthy(_ retryKey: String) {
        set(.healthy, for: retryKey)
    }

    /// Mark unhealthy with error description and save.
    func markUnhealthy(_ retryKey: String, error: String?) {
        set(.unhealthy(failedAt: Date(), error: error), for: retryKey)
    }

    /// Clear all health records.
    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
        isDirty = true
        saveInternal()
    }

    /// Clear records for accounts whose id starts with accountID.
    func clear(accountIDs: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for id in accountIDs {
            let prefix = "\(id)|"
            cache.keys.filter { $0.hasPrefix(prefix) }.forEach { cache.removeValue(forKey: $0) }
        }
        isDirty = true
        saveInternal()
    }

    /// All retryKeys that are currently unhealthy.
    var excludedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cache.filter { _, rec in
            if case .unhealthy = rec.status { return true }
            return false
        }.map(\.key)
    }

    // MARK: - Health Check Run

    /// Probe all models from all accounts in the background.
    /// `onProgress` called on main with (retryKey, isHealthy, error) for each result.
    /// Runs entirely off-main using Task.detached.
    func runHealthCheck(
        accounts: [AgentAccount],
        onProgress: @escaping @MainActor (String, Bool, String?) -> Void,
        completion: @escaping @MainActor () -> Void
    ) {
        Task.detached { [weak self] in
            guard let self else { return }
            let candidates = self.buildCandidates(from: accounts)
            let total = candidates.count

            for (index, (account, model)) in candidates.enumerated() {
                let retryKey = Self.makeRetryKey(
                    provider: account.provider,
                    profileID: account.profileID,
                    model: model
                )

                // Mark probing
                await MainActor.run {
                    self.markProbing(retryKey)
                    onProgress(retryKey, true, nil)
                }

                let (healthy, error) = await self.probe(account: account, model: model)

                await MainActor.run {
                    if healthy {
                        self.markHealthy(retryKey)
                    } else {
                        self.markUnhealthy(retryKey, error: error)
                    }
                    onProgress(retryKey, healthy, error)
                }
            }

            await MainActor.run {
                completion()
            }
        }
    }

    /// Run a health check and post a notification when done.
    func runHealthCheck(accounts: [AgentAccount]) {
        Task.detached { [weak self] in
            guard let self else { return }
            let candidates = self.buildCandidates(from: accounts)

            for (account, model) in candidates {
                let retryKey = Self.makeRetryKey(
                    provider: account.provider,
                    profileID: account.profileID,
                    model: model
                )
                self.markProbing(retryKey)
                let (healthy, error) = await self.probe(account: account, model: model)
                if healthy {
                    self.markHealthy(retryKey)
                } else {
                    self.markUnhealthy(retryKey, error: error)
                }
            }

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .modelHealthCheckDidFinish,
                    object: nil
                )
            }
        }
    }

    // MARK: - Private

    private struct Record: Codable {
        var status: ModelHealthStatus
        var lastProbedAt: Date
        var lastError: String?
    }

    private enum ModelHealthStatus: Codable {
        case healthy
        case unhealthy(failedAt: Date, error: String?)
        case probing
    }

    private func buildCandidates(from accounts: [AgentAccount]) -> [(AgentAccount, String)] {
        let enabled = EnabledModels.accounts(from: accounts)
        return enabled.flatMap { account in
            (account.models ?? []).map { model in (account, model) }
        }
    }

    /// Send a lightweight probe request. Healthy = got any HTTP response.
    private func probe(account: AgentAccount, model: String) async -> (Bool, String?) {
        guard let baseURL = account.baseURL,
              let url = URL(string: "\(baseURL)/chat/completions")
        else {
            return (false, "Invalid base URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (false, "Invalid response")
            }
            // Got a response — endpoint is reachable
            let healthy = (200..<300).contains(http.statusCode)
            if healthy {
                return (true, nil)
            } else {
                // Server responded but with error code: still reachable
                return (false, "HTTP \(http.statusCode)")
            }
        } catch let error as NSError {
            if error.domain == NSURLErrorDomain {
                switch error.code {
                case NSURLErrorTimedOut:
                    return (false, "Timeout")
                case NSURLErrorNotConnectedToInternet:
                    return (false, "No internet")
                case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                    return (false, "Cannot connect")
                default:
                    return (false, "Network error")
                }
            }
            return (false, error.localizedDescription)
        }
    }

    private static func makeRetryKey(provider: AgentProvider, profileID: String?, model: String) -> String {
        "\(provider.rawValue)|\(profileID ?? "")|\(model)"
    }

    private func set(_ status: ModelHealthStatus, for retryKey: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[retryKey] = Record(status: status, lastProbedAt: Date(), lastError: nil)
        isDirty = true
        saveInternal()
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return }
        cache = decoded
    }

    private func saveInternal() {
        let snapshot = cache
        lock.unlock()
        // Already unlocked; snapshot captured at lock time
        lock.lock()
        if let encoded = try? JSONEncoder().encode(snapshot) {
            defaults.set(encoded, forKey: storageKey)
        }
        isDirty = false
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when a single model health result arrives: userInfo["retryKey": String, "healthy": Bool].
    static let modelHealthDidUpdate = Notification.Name("wiki.qaq.apelin.modelHealthDidUpdate")
    /// Posted when the full health check run finishes.
    static let modelHealthCheckDidFinish = Notification.Name("wiki.qaq.apelin.modelHealthCheckDidFinish")
}
