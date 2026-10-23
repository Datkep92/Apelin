import Foundation
import KWWKAgent
import KWWKAI

/// The stream a session's agent runs on: kwwk's own, asking for the
/// processing tier the app last chose. kwwk's loop builds each request's
/// options itself and never sets a tier, so this is where it goes in; for
/// ChatGPT Codex, kwwk still drops a tier the model's catalog does not list.
final class ServiceTierStream: @unchecked Sendable {
    private let lock = NSLock()
    private var chosen: ServiceTier?

    init(tier: ServiceTier?) {
        chosen = tier
    }

    var tier: ServiceTier? {
        get { lock.withLock { chosen } }
        set { lock.withLock { chosen = newValue } }
    }

    var streamFn: StreamFn {
        { [self] model, context, options in
            var options = options ?? StreamOptions()
            options.serviceTier = tier
            return try await KWWKAI.stream(model: model, context: context, options: options)
        }
    }

    /// kwwk's default auto-compaction. An agent with a stream of its own
    /// leaves native compaction (Codex's, Anthropic's) off unless one is
    /// named, so kwwk's own is named here.
    static var autoCompact: AgentAutoCompactOptions {
        AgentAutoCompactOptions(config: AgentContextCompactionConfig(nativeCompaction: compactNative))
    }
}
