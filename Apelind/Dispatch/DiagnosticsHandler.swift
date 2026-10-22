import ApelinProtocol

/// Load confirmation and UI verification, served by apelin-diagnostics.
/// A load check is a task the host owns, so the respring it may trigger —
/// which takes the app down, not the host — cannot lose its answer.
enum DiagnosticsHandler: DomainHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .confirmLoaded:
            await host.startTask(request, kind: .confirmLoaded, role: .diagnostics)
        case .confirmLoadedAttach:
            await host.attach(request, ConfirmLoadedAttachRequest.self)
        case .captureScreen, .readUITree, .uiAction:
            await host.forward(request, to: .diagnostics)
        default:
            request.fail(ApelinError(
                .badRequest,
                "\(request.operation.rawValue) is not a diagnostics operation",
            ))
        }
    }
}
