import ApelinProtocol
import Foundation

extension Notification.Name {
    static let composerModelSelectionChanged = Notification.Name("wiki.qaq.apelin.composerModelSelectionChanged")
}

/// One model preference for every composer, restored before the catalog loads.
struct ComposerModelSelection: Codable, Equatable {
    var provider: AgentProvider
    var model: String
    /// The last catalog snapshot, so the effort control also restores offline.
    var supportedEfforts: [AgentReasoningEffort]
    var effort: AgentReasoningEffort?
    /// The tiers the model offers, from the same snapshot; absent in a
    /// selection saved before there were any.
    var supportedTiers: [AgentServiceTier]?
    /// Absent is the provider's standard tier.
    var tier: AgentServiceTier?

    static var current: Self? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "composer.modelSelection") else { return nil }
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        set {
            UserDefaults.standard.set(
                newValue.flatMap { try? JSONEncoder().encode($0) },
                forKey: "composer.modelSelection",
            )
            NotificationCenter.default.post(name: .composerModelSelectionChanged, object: nil)
        }
    }
}
