import Dispatch
import Foundation

/// Whether apelind has work, and whether the idle guard could let it exit.
///
/// This fork keeps the daemon up: `normalIdleGraceSeconds` is 0, so the timer
/// never fires and launchd's `KeepAlive` is the only restart path. The ledger
/// still tracks connections, requests and session work, so the host's report
/// says what the backend is doing and a future on-demand build can restore
/// the old exit rule by setting a grace again.
///
/// Every method runs on `queue`.
final class WorkLedger: @unchecked Sendable {
    private let queue: DispatchQueue
    private static let normalIdleGraceSeconds = 0 // 0 = never exit (sleep mode)
    private let onIdle: () -> Void
    private var connections = 0
    private var requests = 0
    private(set) var sessionBusy = false
    private var idleTimer: DispatchWorkItem?

    init(queue: DispatchQueue, onIdle: @escaping () -> Void) {
        self.queue = queue
        self.onIdle = onIdle
    }

    private var isIdle: Bool {
        connections == 0 && requests == 0 && !sessionBusy
    }

    /// Starts the clock: a launch that never sees a client still exits.
    func start() {
        reevaluate()
    }

    func connectionOpened() {
        connections += 1
        reevaluate()
    }

    func connectionClosed() {
        connections -= 1
        reevaluate()
    }

    func requestBegan() {
        requests += 1
        reevaluate()
    }

    func requestEnded() {
        requests -= 1
        reevaluate()
    }

    func sessionReported(busy: Bool, gatewayRunning: Bool) {
        self.sessionBusy = busy
        reevaluate()
    }

    private func reevaluate() {
        dispatchPrecondition(condition: .onQueue(queue))
        idleTimer?.cancel()
        idleTimer = nil
        guard isIdle else { return }
        let timeout = Self.normalIdleGraceSeconds
        guard timeout > 0 else { return } // sleep mode: never exit
        NSLog("apelind: idle, exiting in %d s unless work arrives", timeout)
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            onIdle()
        }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + .seconds(timeout), execute: timer)
    }
}
