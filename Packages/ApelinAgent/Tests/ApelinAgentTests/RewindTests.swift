@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

/// Going back to a message the reader already sent: the session's event log
/// and the transcript are cut at the same place, the project's files are put
/// back from the copies a write kept, and the text comes back to the composer
/// under a new id when it is sent again.
@Suite("Edit and run again")
struct RewindTests {
    @Test
    func `cutting the log keeps the message and drops everything after it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let sessionID = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        let id = UUID()
        try await log.append(.userMessage(id: id, text: "Build it", attachments: []))
        try await log.append(.textDelta("Working on it"))
        try await log.append(.userMessage(id: UUID(), text: "And then this", attachments: []))
        let target = try #require(try await log.records(afterSeq: 0).first {
            if case let .userMessage(messageID, _, _, _) = $0.event { return messageID == id }
            return false
        })
        try await log.truncate(afterSeq: target.seq)
        let kept = try await log.records(afterSeq: 0)
        #expect(kept.count == 1, "the message stays, its reply and the next message go")
        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: sessionID)
        #expect(try await reopened.records(afterSeq: 0).count == 1, "and the cut survives reopening")
        try await reopened.append(.textDelta("A new answer"))
        #expect(try await reopened.records(afterSeq: target.seq).count == 1, "with numbers continuing from the cut")
        await reopened.close()
        await log.close()
    }

    @Test
    func `a copy of each changed path is found again and restores only files still there`() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let backups = FileBackups(
            directory: FileBackups.directory(for: home.project.name, dataRoot: home.dataRoot),
        )
        try home.write("notes.md", "before")
        let name = try #require(try backups.save(Data("before".utf8), path: "notes.md"))
        #expect(try backups.readManifest()[name] == "notes.md", "the copy knows its path")
        #expect(try backups.save(Data("before".utf8), path: "notes.md") == nil, "unchanged bytes make no second copy")

        try home.write("notes.md", "after")
        try backups.save(Data("gone".utf8), path: "deleted.md", at: Date(timeIntervalSince1970: 1_700_000_000))
        let tools = ProjectFileTools(root: try ScopedRoot(home.projectURL), backups: backups)
        let restored = try tools.restoreChanges(since: Date().addingTimeInterval(-60))
        #expect(restored == 1, "a file that no longer exists is not brought back")
        #expect(try home.read("notes.md") == "before")
    }

    @Test(.timeLimit(.minutes(1)))
    func `going back to an earlier message cuts the later ones`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage("First answer.")),
            .message(fauxAssistantMessage("Second answer.")),
            .message(fauxAssistantMessage("Third answer.")),
        ])
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .registered(faux.getModel()),
            approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot,
        )
        let session = try await AgentSession(
            configuration: configuration, backend: MockBackend(),
            digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        let first = UUID()
        let second = UUID()
        try await session.prompt("First message", messageID: first)
        await session.waitForIdle()
        try await session.prompt("Second message", messageID: second)
        await session.waitForIdle()

        let before = try await session.log.records(afterSeq: 0)
        let target = try #require(before.first {
            if case let .userMessage(id, _, _, _) = $0.event { return id == first }
            return false
        })
        let response = try await session.rewind(to: first)
        #expect(response.lastSeq == target.seq)
        let after = try await session.log.records(afterSeq: 0)
        #expect(after.last?.seq == target.seq, "the log ends at the message being edited")
        #expect(after.count < before.count, "the later events are gone")
        #expect(after.contains {
            if case let .userMessage(id, _, _, _) = $0.event { return id == second }
            return false
        } == false, "and the later message is gone")
        await session.close()

        // The same words are sent under a new id: no old row is mistaken for
        // this one when the app puts the edited text in the composer.
        let resumed = try await AgentSession(
            configuration: configuration, backend: MockBackend(),
            digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        let new = UUID()
        try await resumed.prompt("First message, edited", messageID: new)
        await resumed.waitForIdle()
        let ids = try await resumed.log.records(afterSeq: 0).compactMap { record -> UUID? in
            if case let .userMessage(id, _, _, _) = record.event { return id }
            return nil
        }
        #expect(ids == [first, new], "the earlier message stays under its own id")
        await resumed.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func `going back to a message that was queued cuts the turn that took it`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        faux.setResponses([
            .factory { _, _, _, _ in
                start.yield()
                for await _ in released { break }
                return fauxAssistantMessage("First.")
            },
            .message(fauxAssistantMessage("Second.")),
        ])
        let configuration = AgentSessionConfiguration(
            project: home.project, provider: .registered(faux.getModel()),
            approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot,
        )
        let session = try await AgentSession(
            configuration: configuration, backend: MockBackend(),
            digests: MockDigestLedger(), credentials: DeliveredCredentialSource(),
        )
        let first = UUID()
        let second = UUID()
        try await session.prompt("First message", messageID: first)
        for await _ in started { break }
        try await session.prompt("Second message", messageID: second)
        release.yield()
        await session.waitForIdle()

        let records = try await session.log.records(afterSeq: 0)
        let queued = try #require(records.first {
            if case let .userMessageQueued(id, _, _, _) = $0.event { return id == second }
            return false
        })
        let response = try await session.rewind(to: second)
        #expect(response.lastSeq == queued.seq, "the cut starts at the queued event, not the later copy")
        let after = try await session.log.records(afterSeq: 0)
        #expect(after.last?.seq == queued.seq)
        #expect(after.contains {
            if case let .userMessage(id, _, _, _) = $0.event { return id == second }
            return false
        } == false, "the later copy of the queued message goes too")
        await session.close()
    }
}
