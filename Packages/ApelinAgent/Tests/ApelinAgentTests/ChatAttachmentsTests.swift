@testable import ApelinAgent
import ApelinProtocol
import CoreGraphics
import Foundation
import ImageIO
import KWWKAgent
import KWWKAI
import Testing

@Suite("Chat attachments and temporary workspaces")
struct ChatAttachmentsTests {
    @Test
    func `Attachments persist, replay and deduplicate a retried send`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([.message(fauxAssistantMessage("Read the attachment."))])
        let configuration = AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let id = UUID()
        let data = Data("# Shared notes\nHello from a file.".utf8)
        try await session.prompt("Read this", messageID: id, files: [("../notes.md", "text/markdown", data)])
        await session.waitForIdle()
        try await session.prompt("Read this", messageID: id, files: [("../notes.md", "text/markdown", data)])
        let records = try await session.log.records(afterSeq: 0)
        let messages = records.compactMap { record -> [ApelinProtocol.AgentAttachment]? in
            if case let .userMessage(messageID, _, files) = record.event, messageID == id {
                return files
            }
            return nil
        }
        #expect(messages.count == 1)
        let file = try #require(messages.first?.first)
        #expect(file.name == "../notes.md")
        #expect(file.path.hasPrefix("Attachments/"))
        #expect(try Data(contentsOf: home.projectURL.appendingPathComponent(file.path)) == data)
        await session.close()
        let resumed = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await resumed.prompt("Read this", messageID: id)
        #expect(try await resumed.log.records(afterSeq: 0).filter {
            if case .userMessage = $0.event {
                return true
            }; return false
        }.count == 1)
        await resumed.close()
    }

    @Test
    func `Tool images survive the event log as saved attachments`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        faux.setResponses([
            .message(fauxAssistantMessage(blocks: [fauxToolCall(name: "apelin_screen_capture", arguments: ["reason": "Look at the screen"])], stopReason: .toolUse)),
            .message(fauxAssistantMessage("Here is the screen.")),
        ])
        let session = try await AgentSession(configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        try await session.prompt("Capture the screen")
        await session.waitForIdle()
        let records = try await session.log.records(afterSeq: 0)
        let files = records.compactMap { record -> ApelinProtocol.AgentAttachment? in
            if case let .toolCallFinished(result) = record.event {
                return result.attachments?.first
            }
            return nil
        }
        let file = try #require(files.first)
        #expect(file.mimeType == "image/png")
        #expect(try Data(contentsOf: home.projectURL.appendingPathComponent(file.path)) == Data([0x89, 0x50]))
        await session.close()
    }

    @Test
    func `A temporary chat is confined to its own UUID directory`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let folder = home.dataRoot.url.appendingPathComponent("Temporary/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let identity = try ProjectIdentity(id: "temporary:" + id, name: ProjectName(id))
        let configuration = AgentSessionConfiguration(project: identity, temporaryID: id, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .confirm), dataRoot: home.dataRoot)
        let session = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        await session.close()
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: home.projectURL)
        await #expect(throws: (any Error).self) {
            _ = try await AgentSession(configuration: configuration, backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        }
    }

    @Test
    func `a message's picture is sent as the endpoint takes it, and its file keeps the bytes`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let sent = SentImages()
        faux.setResponses([.factory { context, _, _, _ in
            for message in context.messages {
                guard case let .user(user) = message else { continue }
                for block in user.content {
                    if case let .image(image) = block { await sent.add(image) }
                }
            }
            return fauxAssistantMessage("Seen.")
        }])
        let photo = try #require(FileReadImageTests.encoded(
            [FileReadImageTests.picture(width: 4000, height: 3000, noise: true)],
            as: "public.jpeg",
            quality: 0.9,
        ))
        let session = try await AgentSession(configuration: AgentSessionConfiguration(project: home.project, provider: .registered(faux.getModel()), approval: ApprovalPolicy(mode: .relaxed), dataRoot: home.dataRoot), backend: MockBackend(), digests: MockDigestLedger(), credentials: DeliveredCredentialSource())
        let id = UUID()
        try await session.prompt("Look at this", messageID: id, files: [("photo.jpg", "image/jpeg", photo)])
        await session.waitForIdle()

        // The attachment's file is the picture as it was attached.
        let records = try await session.log.records(afterSeq: 0)
        let files = records.compactMap { record -> [ApelinProtocol.AgentAttachment]? in
            if case let .userMessage(messageID, _, files) = record.event, messageID == id {
                return files
            }
            return nil
        }
        let file = try #require(files.first?.first)
        #expect(try Data(contentsOf: home.projectURL.appendingPathComponent(file.path)) == photo)

        // What the model was given is a copy of it within the endpoint's
        // limits: the faux provider's model speaks the OpenAI-compatible API.
        let given = await sent.all
        #expect(given.count == 1)
        let first = try #require(given.first)
        #expect(first.mimeType == "image/jpeg")
        let shown = try #require(Self.decoded(first))
        #expect(max(shown.width, shown.height) <= MessageImageLimits.openAICompatible.longestSide)
        #expect(try Data(base64Encoded: first.data) != photo)

        // Sent again, the same picture is the same copy, byte for byte.
        try await session.prompt("And again", messageID: UUID(), files: [("photo.jpg", "image/jpeg", photo)])
        await session.waitForIdle()
        let images = await sent.all
        // The second request carries the whole conversation, so the picture is
        // given once in each of the two messages: three in all, and every one
        // of them the copy made first.
        #expect(images.count == 3)
        #expect(images.allSatisfy { $0.data == first.data })
        await session.close()
    }

    private static func decoded(_ image: ImageContent) -> CGImage? {
        guard let data = Data(base64Encoded: image.data) else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// The pictures the provider was given.
private actor SentImages {
    var all: [ImageContent] = []

    func add(_ image: ImageContent) {
        all.append(image)
    }
}
