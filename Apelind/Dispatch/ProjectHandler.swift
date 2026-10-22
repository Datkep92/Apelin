import ApelinProtocol

/// Extensions, templates and projects, served by apelin-build.
enum ProjectHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .extensionList, .projectCreate, .projectCheck, .projectRename:
            await host.forward(request, to: .build)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a project operation"))
        }
    }
}
