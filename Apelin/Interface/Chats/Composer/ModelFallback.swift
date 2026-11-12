import Foundation

/// Whether a run that failed on every key for the model it sent with may send
/// the reader's message again with *another* model.
///
/// Off unless the reader turns it on. Another key for the same model needs no
/// setting — the model answers the same question — while another model is a
/// different answer, and a conversation that changes model on its own is not
/// what the reader asked for. `ModelCandidates.fallbackList` reads it for the
/// last two steps of its order; Settings ▸ Agent ▸ Models writes it, and the
/// same switch's subtitle says what it does.
enum ModelFallback {
    private static let key = "chat.triesOtherModels"

    static var triesOtherModels: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
