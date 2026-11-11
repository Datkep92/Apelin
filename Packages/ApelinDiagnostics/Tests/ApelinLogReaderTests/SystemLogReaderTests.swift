import ApelinDiagnosticsCore
@testable import ApelinLogReader
import os
import XCTest

final class SystemLogReaderTests: XCTestCase {
    func testFiltersAreCheckedBeforeTheStreamOpens() {
        XCTAssertThrowsError(try SystemLogReader().readLogs(LogFilter(duration: 120)))
        XCTAssertThrowsError(try SystemLogReader().readLogs(LogFilter(maxEntries: 0)))
    }

    func testFilterMatching() {
        let entry = LogEntry(
            date: Date(timeIntervalSince1970: 100),
            process: "SpringBoard",
            pid: 800,
            subsystem: "wiki.qaq.apelin.hello",
            category: "ui",
            level: .default,
            message: "ApelinHello: loaded into SpringBoard",
        )
        XCTAssertTrue(LogFilter(subsystem: "wiki.qaq.apelin").matches(entry))
        XCTAssertFalse(LogFilter(subsystem: "wiki.qaq.ape").matches(entry), "dotted children only")
        XCTAssertTrue(LogFilter(process: "springboard").matches(entry))
        XCTAssertFalse(LogFilter(process: "Spring").matches(entry))
        XCTAssertFalse(LogFilter(messageContains: "apelinhello").matches(entry), "case-sensitive")
        XCTAssertFalse(LogFilter(minimumLevel: .error).matches(entry))
        XCTAssertTrue(LogFilter(minimumLevel: .info).matches(entry))
        XCTAssertFalse(LogFilter(since: Date(timeIntervalSince1970: 101)).matches(entry))
    }

    func testLogTypesMapToLevels() {
        XCTAssertEqual(LogLevel(logType: 0x00), .default)
        XCTAssertEqual(LogLevel(logType: 0x01), .info)
        XCTAssertEqual(LogLevel(logType: 0x02), .debug)
        XCTAssertEqual(LogLevel(logType: 0x10), .error)
        XCTAssertEqual(LogLevel(logType: 0x11), .fault)
        XCTAssertEqual(LogLevel(logType: 0x42), .default)
    }

    /// The live stream on the Mac: a line this process logs while the reader
    /// listens. diagnosticd may refuse an unentitled reader — then it answers
    /// nothing, and the test says so rather than failing.
    func testAReadIsBoundedAndSeesOwnLine() throws {
        let marker = "apelin-log-reader-test-\(UUID().uuidString)"
        let logger = Logger(subsystem: "wiki.qaq.apelin.tests", category: "reader")
        let started = Date()
        let emitter = DispatchWorkItem {
            for _ in 0 ..< 10 {
                logger.error("\(marker, privacy: .public)")
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3, execute: emitter)
        let result: LogReadResult
        do {
            result = try SystemLogReader().readLogs(LogFilter(
                subsystem: "wiki.qaq.apelin.tests",
                messageContains: marker,
                duration: 2,
                maxEntries: 3,
            ))
        } catch let DiagnosticsError.unavailable(reason) {
            throw XCTSkip("live stream unavailable: \(reason)")
        }
        emitter.wait()
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "the window bounds the read")
        XCTAssertEqual(result.source, .liveStream)
        try XCTSkipIf(result.entries.isEmpty, "diagnosticd delivered nothing to this process")
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertTrue(result.truncated, "ten lines against a cap of three")
        XCTAssertTrue(result.entries.allSatisfy { $0.message == marker && $0.level == .error })
        XCTAssertEqual(result.entries.first?.pid, getpid())
    }

    /// One listen for the whole window: the forty numbered lines logged across
    /// it keep one stream, in order, with no seam at a chunk boundary. os_log
    /// itself may drop a line under load, so what is promised here is what
    /// arrives: every line once, in order, and the stream still open at the
    /// last one. Skipped when diagnosticd delivers nothing here.
    func testAListenIsOneStreamForItsWholeWindow() throws {
        let marker = "apelin-log-listen-test-\(UUID().uuidString)"
        let logger = Logger(subsystem: "wiki.qaq.apelin.tests", category: "listen")
        let received = Received()
        let listener = try SystemLogReader().listen(
            LogFilter(subsystem: "wiki.qaq.apelin.tests", messageContains: marker),
            until: Date().addingTimeInterval(30),
        ) { entry in
            received.append(entry.message)
            return true
        }
        // The stream connects to diagnosticd asynchronously after it opens.
        Thread.sleep(forTimeInterval: 0.5)
        for index in 0 ..< 40 {
            logger.error("\(marker, privacy: .public) \(index, privacy: .public)")
            Thread.sleep(forTimeInterval: 0.06)
        }
        // The promise is that the window's last line arrives, not that it
        // arrives within a fixed second: logd may hand the tail over late when
        // the machine is busy, and closing the listener drops whatever is
        // still in flight. So wait for it, with a bound — a listen that never
        // delivers it fails the assertion below either way.
        let tail = Date().addingTimeInterval(10)
        while Date() < tail, !received.messages.contains(where: { Int($0.split(separator: " ").last ?? "") == 39 }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        listener.finish()
        XCTAssertFalse(try listener.wait(), "the root reader drops nothing")
        let messages = received.messages
        try XCTSkipIf(messages.isEmpty, "diagnosticd delivered nothing to this process")
        let indexes = messages.compactMap { Int($0.split(separator: " ").last ?? "") }
        XCTAssertEqual(indexes.count, messages.count, "every line carries its number")
        XCTAssertEqual(Set(indexes).count, indexes.count, "each line arrives once")
        XCTAssertEqual(indexes, indexes.sorted(), "in the order they were logged")
        XCTAssertEqual(indexes.last, 39, "the window's last line: no seam cut the stream short")
        XCTAssertGreaterThanOrEqual(indexes.count, 30, "os_log dropped \(40 - indexes.count) of 40")
        logger.error("\(marker, privacy: .public) after")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(received.messages.count, indexes.count, "nothing after the end")
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ message: String) {
        lock.lock(); items.append(message); lock.unlock()
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}
