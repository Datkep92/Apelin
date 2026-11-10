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
        let isRunning = gatewayIsRunning()
        let pid = lastPID(from: URL(fileURLWithPath: "/var/run/gateway-session.pid"))
        guard let data = try? Data(contentsOf: file),
              let record = try? JSONDecoder().decode(GatewayRecord.self, from: data) else {
            return GatewayRecord(state: .dang_treo, enabled: false, pid: nil, since: nil)
        }
        let state: GatewayState = isRunning ? .dang_chay : .dang_treo
        return GatewayRecord(state: state, enabled: record.enabled, pid: isRunning ? pid : nil, since: isRunning ? nil : record.since)
    }

    private static func writeStateFile(file: URL, enabled: Bool, since: Date) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = GatewayRecord(state: .dang_treo, enabled: enabled, since: since)
        let data = try JSONEncoder().encode(record)
        try data.write(to: file)
    }

    private static func gatewayIsRunning() -> Bool {
        let exists = FileManager.default.fileExists(atPath: bin)
        let pid = lastPID(from: URL(fileURLWithPath: "/var/run/gateway-session.pid"))
        let isRunning = pid.map { kill(Int32($0), 0) == 0 } ?? false
        return exists && isRunning
    }

    private static func lastPID(from url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8),
              let pid = Int(text.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return pid
    }

    private static func start(host: SessionHost) async throws {
        let home = host.home
        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        readHandle.closeFile()
        let writeFd = writeHandle.fileDescriptor
        
        // Set environment with HOME and possibly PATH, but we only set HOME for simplicity
        let environment: [String] = ["HOME=\(home)"]
        
        // Use spawnProcess to start gateway as non-root (mobile identity)
        _ = try spawnProcess(path: shell, arguments: ["sh", bin], environment: environment, channel: Int32(writeFd), identity: .mobile)
        
        // Close our end of the channel after starting
        writeHandle.closeFile()
        try await Task.sleep(nanoseconds: 500_000_000) // give gateway time to bind the socket
    }

    private static func stop() async throws {
        let pid = try spawnProcess(path: shell, arguments: ["sh", ctl, "stop"], environment: [], channel: 0, identity: nil)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let pidFile = URL(fileURLWithPath: "/var/run/gateway-session.pid")
        try? FileManager.default.removeItem(at: pidFile)
    }
}
