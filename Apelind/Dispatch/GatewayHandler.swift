import Darwin
import Foundation
import ApelinCore
import ApelinProtocol

/// The Apelind side: `.gatewayStatus` and `.gatewaySetEnabled` that
/// reports to (and controls) the gateway process on port 15199.
enum GatewayHandler: DomainHandler {
    static let shell = "/var/jb/bin/sh"
    static let bin = "/var/jb/usr/bin/gateway-session"
    static let ctl = "/var/jb/usr/bin/gatewayctl"

    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        switch request.operation {
        case .gatewayStatus:
            return await request.serve(GatewayStatusRequest.self) { _ in
                let stateFile = host.dataFolder.root.appendingPathComponent("gateway.json")
                let record = await readState(file: stateFile)
                return GatewayStatusResponse(record: record)
            }

        case .gatewaySetEnabled:
            return await request.serve(GatewaySetEnabledRequest.self) { [self] req in
                let stateFile = host.dataFolder.root.appendingPathComponent("gateway.json")
                try await writeStateFile(file: stateFile, enabled: req.enabled, since: Date())
                let isRunning = gatewayIsRunning()
                if isRunning {
                    try? await stop()
                }
                if req.enabled {
                    try? await start(host: host)
                }
                return Acknowledged()
            }

        default:
            return request.fail(ApelinError(.internal, "unmapped gateway operation"))
        }
    }

    private static func readState(file: URL) async -> GatewayRecord {
        let stateString = gatewayStateString()
        let isRunning = stateString == "dang_chay"
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(GatewayRecord.self, from: data) else {
            return GatewayRecord(state: isRunning ? .dang_chay : .khong_chay, enabled: false, pid: nil, since: nil)
        }
        let state: GatewayState
        switch stateString {
        case "dang_chay": state = .dang_chay
        case "dang_treo": state = .dang_treo
        default: state = .khong_chay
        }
        return GatewayRecord(state: state, enabled: record.enabled, pid: nil, since: isRunning ? nil : record.since)
    }

    private static func writeStateFile(file: URL, enabled: Bool, since: Date) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = GatewayRecord(state: .khong_chay, enabled: enabled, since: since)
        let data = try JSONEncoder().encode(record)
        try data.write(to: file)
    }

    static func gatewayStateString() -> String {
        runGatewayCtl(["state"])
    }

    static func gatewayIsRunning() -> Bool {
        gatewayStateString() == "dang_chay"
    }

    static func gatewayHasProcess() -> Bool {
        let state = gatewayStateString()
        return state != "khong_chay"
    }

    private static func runGatewayCtl(_ args: [String]) -> String {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return "" }
        let readFD = fds[0]
        let writeFD = fds[1]

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)

        var everySignal = sigset_t()
        var noSignal = sigset_t()
        sigfillset(&everySignal)
        sigemptyset(&noSignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        posix_spawnattr_setflags(&attributes, flags)

        var groups: [gid_t] = [501]
        _ = spawnSetGroups(&attributes, 1, &groups, 501)
        _ = spawnSetGID(&attributes, 501)
        _ = spawnSetUID(&attributes, 501)

        let commandArgs = [shell, ctl] + args
        var cArgs = commandArgs.map { strdup($0) }
        cArgs.append(nil)
        let envStrings = ["HOME=/var/mobile", "PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin"]
        var cEnv = envStrings.map { strdup($0) }
        cEnv.append(nil)

        var pid: pid_t = 0
        let status = cArgs.withUnsafeMutableBufferPointer { argvPtr in
            cEnv.withUnsafeMutableBufferPointer { envPtr in
                posix_spawn(&pid, shell, &actions, &attributes, argvPtr.baseAddress, envPtr.baseAddress)
            }
        }
        cArgs.forEach { free($0) }
        cEnv.forEach { free($0) }

        guard status == 0 else {
            close(readFD)
            close(writeFD)
            return ""
        }
        do {
            try verifyDropped(pid, to: .mobile)
        } catch {
            kill(pid, SIGKILL)
            var ignored: Int32 = 0
            waitpid(pid, &ignored, 0)
            close(readFD)
            close(writeFD)
            return ""
        }

        close(writeFD)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readFD, &buffer, buffer.count)
            if n <= 0 { break }
            output.append(buffer, count: Int(n))
        }
        close(readFD)

        var waitStatus: Int32 = 0
        waitpid(pid, &waitStatus, 0)
        return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func start(host: SessionHost) async throws {
        let home = host.home
        // Already running: nothing to do.
        if gatewayStateString() == "dang_chay" {
            return
        }
        // Use gatewayctl's standalone launch, which backgrounds gateway-session
        // in standalone mode and waits for the port to answer.
        let pid = try spawnProcess(path: shell, arguments: [shell, ctl, "on"], environment: ["HOME=\(home)"], channel: 0, identity: .mobile)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    private static func stop() async throws {
        let pid = try spawnProcess(path: shell, arguments: [shell, ctl, "off"], environment: [], channel: 0, identity: .mobile)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}
