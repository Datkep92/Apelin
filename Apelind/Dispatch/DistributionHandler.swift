import ApelinProtocol

/// The user's package repository, served by apelin-environment, which holds
/// the github.com sign-in. The app's alone: no worker may call these
/// (CallerPolicy). Its tasks are not resumed: each talks to GitHub, and the
/// one cut off is answered by running it again, which a link does safely.
enum DistributionHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .distributionRepositoryList, .distributionRepositoryUnlink:
            await host.forward(request, to: .environment)
        case .distributionRepositoryCreate, .distributionRepositoryLink, .distributionPublish:
            await host.startTask(request, kind: .environment, role: .environment, resumable: false)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a distribution operation"))
        }
    }
}
