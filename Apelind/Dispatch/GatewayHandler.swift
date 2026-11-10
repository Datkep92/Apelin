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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = [ctl] + args
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func start(host: SessionHost) async throws {
        let home = host.home
        // Already running: nothing to do.
        if gatewayStateString() == "dang_chay" {
            return
        }
        // Use gatewayctl's standalone launch, which backgrounds gateway-session
        // in standalone mode and waits for the port to answer.
        let pid = try spawnProcess(path: shell, arguments: [ctl, "on"], environment: ["HOME=\(home)"], channel: 0, identity: .mobile)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    private static func stop() async throws {
        let pid = try spawnProcess(path: shell, arguments: [ctl, "off"], environment: [], channel: 0, identity: .mobile)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}
