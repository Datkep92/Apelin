import ApelinCore
import ApelinProtocol

/// Extensions, templates and projects, served by apelin-build.
enum ProjectHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if request.operation == .projectRename, case let .worker(.agent, instance) = request.caller {
            guard let rename = try? JSONCoding.decode(ProjectRenameRequest.self, from: request.request.payload) else {
                return request.fail(ApelinError(.badRequest, "projectRename names no project"))
            }
            if let refusal = await AgentProjectRenameRules.authorize(rename, session: instance, home: host.home, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        switch request.operation {
        case .extensionList, .projectCreate, .projectCheck, .projectRename:
            return await host.forward(request, to: .build)
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a project operation"))
        }
    }
}
