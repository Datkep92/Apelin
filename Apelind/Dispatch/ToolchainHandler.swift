import ApelinProtocol

/// Toolchain setup and removal, served by apelin-environment.
enum ToolchainHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .toolchainStatus, .toolchainCatalog:
            await host.forward(request, to: .environment)
        case .toolchainSetup, .toolchainRemove:
            await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        case .toolchainSelfTest:
            // quick and harmless to run again by hand: not resumed
            await host.startTask(request, kind: .environment, role: .environment, resumable: false)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a toolchain operation"))
        }
    }
}
