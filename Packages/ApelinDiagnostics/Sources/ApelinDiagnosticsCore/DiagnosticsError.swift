import Foundation

public enum DiagnosticsError: Error, Equatable, Sendable {
    /// A typed parameter was out of its range; nothing was attempted.
    case invalidParameter(String)
    /// The capability does not exist here: no icli on this platform, a private
    /// class missing on this OS, a process without the entitlement it needs.
    /// Not an error to show as a failure — a reason to say "unavailable".
    case unavailable(String)
    /// The device is locked or its screen is off, and the call needs neither.
    case locked
    /// The capability ran and failed.
    case failed(String)
}

extension DiagnosticsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidParameter(message): message
        case let .unavailable(message): message
        case .locked: "Unlock the device and keep its screen on, then try again."
        case let .failed(message): message
        }
    }
}
