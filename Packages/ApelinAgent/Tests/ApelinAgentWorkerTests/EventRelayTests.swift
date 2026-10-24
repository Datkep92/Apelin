import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import Foundation
import Testing

@Suite("The relay coalesces what streams")
struct EventRelayTests {
    /// What a relay emitted, in order.
    final class Emitted: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [(String, ApelinCore.JSONValue?)] = []

        func append(_ kind: String, _ payload: ApelinCore.JSONValue?) {
            lock.withLock { events.append((kind, payload)) }
        }

        var kinds: [String] {
            lock.withLock { events.map(\.0) }
        }

        var tokens: [Double] {
            lock.withLock { events.filter { $0.0 == "received" }.compactMap { $0.1?["tokens"]?.doubleValue } }
        }
    }

    @Test
    func `the received count goes out with the streamed text, only its latest and only when new`() async {
        let emitted = Emitted()
        let relay = EventRelay { emitted.append($0, $1) }
        await relay.relay(.messageStarted)
        await relay.relay(.textDelta("Reading"))
        await relay.relay(.received(tokens: 2))
        await relay.relay(.textDelta(" it."))
        await relay.relay(.received(tokens: 3))
        await relay.relay(.toolCallPreparing)
        // within a quarter second this is one flush; a slow machine may
        // flush between the two, never sending a count twice
        #expect(emitted.kinds.suffix(2) == ["received", "toolCallPreparing"])
        #expect(emitted.tokens.last == 3 && emitted.tokens.count <= 2)
        let sent = emitted.tokens.count
        // a flush with no new count sends none
        await relay.relay(.messageFinished(text: "Reading it."))
        #expect(emitted.tokens.count == sent)
        await relay.relay(.received(tokens: 40))
        await relay.relay(.finished(reason: .completed))
        #expect(emitted.kinds.suffix(2) == ["received", "finished"], "the last count goes before the run's end")
        #expect(emitted.tokens.last == 40 && emitted.tokens.count == sent + 1)
    }
}
