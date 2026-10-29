import ApelinProtocol

/// The user's package repository, served by apelin-environment, which holds
/// the github.com sign-in. The app's alone: no worker may call these
/// (CallerPolicy). Its tasks are not resumed: each talks to GitHub, and the
/// one cut off is answered by running it again, which a link does safely.
///
/// Feedback (`feedbackSend`) is one request to GitHub with the same sign-in,
/// on Apelin's own repository; an agent may send it as AgentFeedbackRules
/// allows, checked here before it is forwarded. Reading and giving that
/// repository a star (`feedbackStarState`, `feedbackStar`) stay the app's.
enum DistributionHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .distributionRepositoryList, .distributionRepositoryUnlink:
            await host.forward(request, to: .environment)
        case .distributionRepositoryCreate, .distributionRepositoryLink, .distributionPublish:
            await host.startTask(request, kind: .environment, role: .environment, resumable: false)
        case .feedbackSend:
            await sendFeedback(request, host: host)
        case .feedbackStarState, .feedbackStar:
            await host.forward(request, to: .environment)
        default:
            request.fail(ApelinError(.badRequest, "\(request.operation.rawValue) is not a distribution operation"))
        }
    }

    private static func sendFeedback(_ request: HostRequest, host: SessionHost) async -> HostReply {
        if case let .worker(.agent, instance) = request.caller {
            let feedback: FeedbackSendRequest
            do {
                feedback = try request.decode(FeedbackSendRequest.self)
            } catch {
                return request.fail(error)
            }
            if let refusal = await AgentFeedbackRules.authorize(feedback, session: instance, registry: host.registry) {
                return request.fail(refusal)
            }
        }
        return await host.forward(request, to: .environment)
    }
}
