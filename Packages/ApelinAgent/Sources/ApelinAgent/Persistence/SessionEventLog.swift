import Foundation
import KWWKAI

public enum SessionStoreError: Error, Equatable, LocalizedError {
    case invalidSessionID(String)
    case corrupt(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSessionID(id): "'\(id)' is not a session id"
        case let .corrupt(detail): "session record is damaged: \(detail)"
        case let .io(detail): detail
        }
    }
}

/// What a session directory remembers besides its events. No credential is
/// ever part of it: the provider is named, the key lives in the
/// `CredentialSource`.
public struct SessionMetadata: Sendable, Hashable, Codable {
    public var id: String
    public var project: ProjectIdentity
    public var provider: ProviderConfiguration
    public var mode: ApprovalMode
    public var created: Date

    public init(
        id: String,
        project: ProjectIdentity,
        provider: ProviderConfiguration,
        mode: ApprovalMode,
        created: Date,
    ) {
        self.id = id
        self.project = project
        self.provider = provider
        self.mode = mode
        self.created = created
    }
}

/// `~/Documents/wiki.qaq.apelin/sessions/<id>/`: `session.json`,
/// `events.jsonl` (one `SessionEventRecord` per line, sequence numbers from
/// 1, appended before delivery) and `transcript.json` (the model
/// conversation, rewritten at the end of every run so a restarted
/// `apelin-agent` resumes it).
///
/// The event log is the only thing an app reattaches to: `attach(afterSeq:)`
/// replays from disk and continues live, with no gap and no duplicate,
/// because both happen inside this actor.
public actor SessionEventLog {
    public let directory: URL
    private var nextSeq: UInt64
    private var handle: FileHandle?
    private var subscribers: [UUID: AsyncStream<SessionEventRecord>.Continuation] = [:]
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Opens (creating if needed) the directory for `sessionID` under
    /// `sessionsRoot`, continuing the sequence after the last valid line.
    public init(sessionsRoot: URL, sessionID: String) throws {
        guard Self.isValidSessionID(sessionID) else { throw SessionStoreError.invalidSessionID(sessionID) }
        let directory = sessionsRoot.appendingPathComponent(sessionID, isDirectory: true)
        try Self.makeDirectory(sessionsRoot)
        try Self.makeDirectory(directory)
        self.directory = directory
        let events = directory.appendingPathComponent("events.jsonl")
        let existing = try Self.readRecords(events)
        nextSeq = (existing.last?.seq ?? 0) + 1
        if !FileManager.default.fileExists(atPath: events.path) {
            guard FileManager.default.createFile(atPath: events.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw SessionStoreError.io("could not create \(events.lastPathComponent)")
            }
        }
        handle = try FileHandle(forWritingTo: events)
        // Drop a torn last line so the next record starts on its own line.
        let data = try Data(contentsOf: events)
        if let last = data.last, last != 0x0A {
            let keep = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            try handle?.truncate(atOffset: UInt64(keep))
        }
        _ = try handle?.seekToEnd()
    }

    /// Session ids are UUIDs, so one can never name a path.
    public static func isValidSessionID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    public var lastSeq: UInt64 {
        nextSeq - 1
    }

    /// Writes the event, then delivers it. Returns the record.
    @discardableResult
    public func append(_ event: AgentSessionEvent) throws -> SessionEventRecord {
        let record = SessionEventRecord(seq: nextSeq, date: Date(), event: event)
        var line = try encoder.encode(record)
        line.append(0x0A)
        try handle?.write(contentsOf: line)
        nextSeq += 1
        for continuation in subscribers.values {
            continuation.yield(record)
        }
        return record
    }

    /// Every record after `afterSeq` from disk, then live ones.
    public func attach(afterSeq: UInt64) throws -> AsyncStream<SessionEventRecord> {
        let replay = try records(afterSeq: afterSeq)
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionEventRecord>.makeStream(bufferingPolicy: .unbounded)
        for record in replay {
            continuation.yield(record)
        }
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.detach(id) }
        }
        return stream
    }

    public func records(afterSeq: UInt64) throws -> [SessionEventRecord] {
        try Self.readRecords(directory.appendingPathComponent("events.jsonl")).filter { $0.seq > afterSeq }
    }

    public func close() {
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
        try? handle?.close()
        handle = nil
    }

    private func detach(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Metadata and transcript

    public func writeMetadata(_ metadata: SessionMetadata) throws {
        try writeAtomically(encoder.encode(metadata), name: "session.json")
    }

    public func readMetadata() throws -> SessionMetadata? {
        let url = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(SessionMetadata.self, from: Data(contentsOf: url))
    }

    public func writeTranscript(_ messages: [Message]) throws {
        try writeAtomically(encoder.encode(messages), name: "transcript.json")
    }

    public func readTranscript() throws -> [Message] {
        let url = directory.appendingPathComponent("transcript.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Self.decoder.decode([Message].self, from: Data(contentsOf: url))
    }

    private func writeAtomically(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        let temporary = directory.appendingPathComponent(".\(name).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw SessionStoreError.io("could not write \(name)")
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw SessionStoreError.io("could not replace \(name)")
        }
    }

    // MARK: - Helpers

    /// Valid records in order. A torn last line (the process died
    /// mid-write) is dropped; damage elsewhere is an error.
    static func readRecords(_ url: URL) throws -> [SessionEventRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var records: [SessionEventRecord] = []
        for (index, line) in lines.enumerated() {
            do {
                try records.append(decoder.decode(SessionEventRecord.self, from: Data(line)))
            } catch {
                if index == lines.count - 1 {
                    break
                }
                throw SessionStoreError.corrupt("line \(index + 1)")
            }
        }
        return records
    }

    private static func makeDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw SessionStoreError.io("\(url.lastPathComponent) is not a folder") }
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
    }
}
