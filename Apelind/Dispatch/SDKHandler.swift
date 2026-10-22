import ApelinProtocol

/// The SDK manager, served by apelin-environment.
enum SDKHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .sdkList, .sdkRemove:
            await host.forward(request, to: .environment)
        case .sdkImport:
            await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not an SDK operation"))
        }
    }
}
