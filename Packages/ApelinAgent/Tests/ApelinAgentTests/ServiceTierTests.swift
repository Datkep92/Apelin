@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// kwwk's loop sets no tier on a request, so the session's own stream puts
/// in the one it was opened with or last configured to.
@Suite("Service tier")
struct ServiceTierTests {
    @Test(.timeLimit(.minutes(1)))
    func `each turn asks for the tier the session was opened with or last configured to`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let seen = SeenTiers()
        let answer = FauxResponseStep.factory { _, options, _, _ in
            await seen.add(options?.serviceTier)
            return fauxAssistantMessage("Done.")
        }
        faux.setResponses([answer, answer, answer])
        let provider = ProviderConfiguration.registered(faux.getModel())
        let credentials = DeliveredCredentialSource()
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: provider,
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
                serviceTier: .priority,
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: credentials,
        )
        try await session.prompt("One", messageID: UUID())
        await session.waitForIdle()
        try await session.configure(provider: provider, thinking: .off, serviceTier: .ultrafast, credentials: credentials)
        try await session.prompt("Two", messageID: UUID())
        await session.waitForIdle()
        try await session.configure(provider: provider, thinking: .off, credentials: credentials)
        try await session.prompt("Three", messageID: UUID())
        await session.waitForIdle()
        #expect(await seen.all == [.priority, .ultrafast, nil])
        await session.close()
    }

    @Test
    func `the session's own stream keeps kwwk's native compaction`() {
        #expect(ServiceTierStream.autoCompact.config.nativeCompaction != nil)
        #expect(ServiceTierStream.autoCompact.threshold == AgentAutoCompactOptions().threshold)
    }
}

private actor SeenTiers {
    private(set) var all: [ServiceTier?] = []

    func add(_ tier: ServiceTier?) {
        all.append(tier)
    }
}
