@testable import ApelinAgent
import Foundation
import KWWKAgent
import KWWKAI
import Testing
import struct ApelinProtocol.AgentAttachment

/// A turn a stopped process was in the middle of: the marker at `turn.json`
/// (`Persistence/SessionEventLog.swift`), and what `AgentSession` does with it
/// — `pendingCutTurn` and `resumeCutTurn`. It is written before the model is
/// asked anything and removed when the run ends, so what is left behind is a
/// turn nothing finished; opening the conversation again sends the same message
/// — the same id, so the app's row is the one it already shows — and counts as
/// recoverable work kept alive after the background service was killed.
@Suite("A turn cut short")
struct CutTurnTests {
    private static func marker(
        messageID: UUID = UUID(),
        text: String = "Build it",
        attachments: [AgentAttachment] = [],
    ) -> InterruptedTurn {
        InterruptedTurn(messageID: messageID, text: text, from: nil, retryOf: nil, attachments: attachments)
    }

    @Test
    func `a turn written before a run is read back by a log opened again`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sessionID = UUID().uuidString
        let attachment = AgentAttachment(path: "notes.md", name: "notes.md", mimeType: "text/markdown")
        let written = InterruptedTurn(
            messageID: UUID(),
            text: "Read it",
            from: "parent-session",
            retryOf: UUID(),
            attachments: [attachment],
        )
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        try await log.writeTurn(written)
        await log.close()

        // A process that stops loses nothing but its memory: the marker is on
        // disk for whichever one opens the session next.
        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        #expect(try await reopened.readTurn() == written)
        #expect(try await reopened.readTurn()?.attachments == [attachment], "the attachments travel with the message")
        await reopened.close()
    }

    @Test
    func `the run's end removes the marker`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        try await log.writeTurn(Self.marker())
        await log.clearTurn()
        #expect(try await log.readTurn() == nil, "a run that ended leaves nothing to take up")
        await log.clearTurn()
        #expect(try await log.readTurn() == nil, "and clearing it twice is not a failure")
        await log.close()
    }

    @Test
    func `a marker that does not read is dropped, not left to fail at every open`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: UUID().uuidString)
        let marker = log.directory.appendingPathComponent("turn.json")
        try Data("not a turn".utf8).write(to: marker)
        #expect(try await log.readTurn() == nil, "nothing can be taken up from it")
        #expect(
            FileManager.default.fileExists(atPath: marker.path) == false,
            "and it is not left where every open would read it again",
        )
        await log.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `opening a conversation takes up the turn a stopped process left`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        provider.setResponses([.message(fauxAssistantMessage("Done."))])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(provider.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        let left = Self.marker(text: "Build it")
        try await session.log.writeTurn(left)
        #expect(await session.pendingCutTurn() == left)

        // A turn another run has started is not this one's to send again.
        var other = left
        other.messageID = UUID()
        #expect(await session.resumeCutTurn(other) == false)
        #expect(await session.pendingCutTurn() == left, "so it is left for the next open")

        #expect(await session.resumeCutTurn(left))
        await session.waitForIdle()

        #expect(await session.pendingCutTurn() == nil, "the run's end removed the marker it wrote again")
        let records = try await session.log.records(afterSeq: 0)
        let notice = records.compactMap { record -> (String?, String)? in
            if case let .notice(title, body) = record.event {
                return (title, body)
            }
            return nil
        }
        .first
        #expect(notice?.0 == nil, "the row it is owed is a transcript row, not a notification")
        #expect(notice?.1.isEmpty == false, "and it says what happened")
        #expect(records.contains { if case .finished = $0.event { true } else { false } }, "the turn ran to its end")
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `a conversation closed while a marker is left has nothing to take up`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let provider = await registerFauxProvider()
        defer { provider.unregister() }
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project, provider: .registered(provider.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
            ),
            backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        try await session.log.writeTurn(Self.marker())
        await session.close()
        #expect(try await session.log.readTurn() == nil, "a conversation the app closed is not carried on when it is opened again")
    }
}
