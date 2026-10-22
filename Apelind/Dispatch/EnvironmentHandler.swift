import ApelinProtocol

/// Environment tasks, read and cancelled in the registry.
enum EnvironmentHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .environmentAttach:
            await host.attach(request, EnvironmentAttachRequest.self)
        case .environmentCancel:
            await host.cancel(request, EnvironmentCancelRequest.self)
        default:
            request.fail(ApelinError(
                .badRequest,
                "\(request.operation.rawValue) is not an environment operation",
            ))
        }
    }
}
