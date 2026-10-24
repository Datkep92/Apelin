import Foundation
import LocalAuthentication

/// Face ID, Touch ID or the passcode, before the reader lets the agent run
/// a command as root: approving one such command, or turning on Full mode.
/// A device with no passcode has no owner to check, and passes.
enum DeviceOwnerCheck {
    /// Whether the owner confirmed with `reason` on the system's prompt, or
    /// the device has no passcode. A cancel, a failure or a policy the
    /// device cannot evaluate for another reason answers false.
    @MainActor
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return error?.domain == LAError.errorDomain && error?.code == LAError.Code.passcodeNotSet.rawValue
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
