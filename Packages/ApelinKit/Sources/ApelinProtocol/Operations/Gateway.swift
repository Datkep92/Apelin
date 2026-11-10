import Foundation

/// Gateway: a second session host running on 127.0.0.1:15199, controlled
/// manually by the user from Apelin. The binary `/var/jb/usr/bin/gateway-session`
/// listens on that port; `/var/jb/usr/bin/gatewayctl` queries its state.
///
/// The app stores enabled state in `~/Documents/wiki.qaq.apelin/gateway.json`.
/// The host checks on launch and updates the cache.

public enum GatewayState: String, Codable, Sendable, Equatable {
    case dang_chay /// running (listening)
    case dang_treo /// suspended (stuck)
    case khong_chay /// not running
}

public struct GatewayRecord: Codable, Sendable, Equatable {
    public var state: GatewayState
    public var enabled: Bool
    public var pid: Int?
    public var since: Date?

    public init(state: GatewayState = .khong_chay, enabled: Bool, pid: Int? = nil, since: Date? = nil) {
        self.state = state
        self.enabled = enabled
        self.pid = pid
        self.since = since
    }
}

public struct GatewayStatusRequest: OperationRequest {
    public typealias Response = GatewayStatusResponse
    public static let operation = AppOperation.gatewayStatus
    public init() {}
}

public struct GatewayStatusResponse: Codable, Sendable, Equatable {
    public var record: GatewayRecord

    public init(record: GatewayRecord) {
        self.record = record
    }
}

public struct GatewaySetEnabledRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.gatewaySetEnabled
    public var enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

public extension ApelinService {
    func gatewayStatus() async throws -> GatewayStatusResponse {
        try await send(GatewayStatusRequest())
    }

    func gatewaySetEnabled(_ enabled: Bool) async throws {
        _ = try await send(GatewaySetEnabledRequest(enabled: enabled))
    }
}
