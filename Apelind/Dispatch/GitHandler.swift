import ApelinCore
import ApelinProtocol

/// The git service on a project, served by apelin-environment (libgit2).
enum GitHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller, !deviceSettings.contains(request.operation),
           let refusal = await agentScopeRefusal(request, sessionID: instance)
        {
            return request.fail(refusal)
        }
        switch request.operation {
        case .gitStatus, .gitDiff, .gitStage, .gitUnstage, .gitCommit,
             .gitSettings, .gitAuthorSet, .gitCredentialSet, .gitCredentialRemove:
            return await host.forward(request, to: .environment)
        case .gitClone:
            return await host.startTask(request, kind: .environment, role: .environment, resumable: true)
        case .gitCloneInto, .gitFetch, .gitPull, .gitPush:
            // Not resumed: a push or pull cut off is answered by running it
            // again, which the caller decides.
            return await host.startTask(request, kind: .environment, role: .environment, resumable: false)
        default:
            return request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a git operation"))
        }
    }

    /// The device's author and credentials, which name no project. An
    /// agent changes them only through the user's approval of each call.
    private static let deviceSettings: Set<AppOperation> = [
        .gitSettings, .gitAuthorSet, .gitCredentialSet, .gitCredentialRemove,
    ]

    /// An agent's git call acts on its own session's project and no other:
    /// a push carries the user's credential for the remote's host.
    private static func agentScopeRefusal(_ request: HostRequest, sessionID: String?) async -> ApelinError? {
        struct Scoped: Decodable { var projectID: String }
        guard let sessionID, let entry = await AgentSessionTable.shared.entry(sessionID) else {
            return ApelinError(.denied, "no agent session for this worker")
        }
        guard let scoped = try? JSONCoding.decode(Scoped.self, from: request.request.payload) else {
            return ApelinError(.badRequest, "\(request.operation.rawValue) names no project")
        }
        guard scoped.projectID == entry.project.id || scoped.projectID == entry.project.name else {
            return ApelinError(.denied, "an agent's git call acts only on its own project")
        }
        return nil
    }
}
