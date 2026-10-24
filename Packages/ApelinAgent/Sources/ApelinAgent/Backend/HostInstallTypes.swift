import Foundation

// MARK: - install / apelin_package_remove / respring

public struct InstallRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var artifactID: String
    /// The host copies the artifact to private staging and checks this
    /// digest before it reaches the installer.
    public var artifactDigest: String
    /// The packaging-description digest the approval was bound to.
    public var packagingDescriptionDigest: String

    public init(
        context: HostCallContext,
        artifactID: String,
        artifactDigest: String,
        packagingDescriptionDigest: String,
    ) {
        self.context = context
        self.artifactID = artifactID
        self.artifactDigest = artifactDigest
        self.packagingDescriptionDigest = packagingDescriptionDigest
    }
}

public struct InstallResponse: Sendable, Hashable, Codable {
    public var transactionID: String
    public var installationID: String?
    public var packageID: String
    public var version: String
    public var succeeded: Bool
    public var message: String

    public init(
        transactionID: String,
        installationID: String?,
        packageID: String,
        version: String,
        succeeded: Bool,
        message: String = "",
    ) {
        self.transactionID = transactionID
        self.installationID = installationID
        self.packageID = packageID
        self.version = version
        self.succeeded = succeeded
        self.message = message
    }
}

public struct RemovePackageRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    /// A host-registered installation record; the host resolves the package.
    public var installationID: String

    public init(context: HostCallContext, installationID: String) {
        self.context = context
        self.installationID = installationID
    }
}

public struct RemovePackageResponse: Sendable, Hashable, Codable {
    public var transactionID: String
    public var succeeded: Bool
    /// Why a removal was refused (unmanaged, replaced externally, …).
    public var message: String

    public init(transactionID: String, succeeded: Bool, message: String = "") {
        self.transactionID = transactionID
        self.succeeded = succeeded
        self.message = message
    }
}

public struct RespringRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) {
        self.context = context
    }
}

public struct RespringResponse: Sendable, Hashable, Codable {
    public var succeeded: Bool
    /// What the app needs to reconnect afterwards.
    public var reconnectHint: String?

    public init(succeeded: Bool, reconnectHint: String? = nil) {
        self.succeeded = succeeded
        self.reconnectHint = reconnectHint
    }
}
