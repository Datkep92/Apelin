import ApelinProtocol

/// The registered toolchains (`Environment/Toolchains/registry.json`).
/// A record is written only after the installed bytes passed self-test; a
/// project binds a toolchain by ID and is never moved to a new default.
public struct ToolchainRegistry: Codable, Sendable, Equatable {
    public var toolchains: [ToolchainRecord] = []
    public var defaultID: String?

    public init(toolchains: [ToolchainRecord] = [], defaultID: String? = nil) {
        self.toolchains = toolchains
        self.defaultID = defaultID
    }

    static func load(_ layout: EnvironmentLayout) -> ToolchainRegistry {
        ((try? JSONFile.read(ToolchainRegistry.self, at: layout.toolchainRegistry)) ?? nil) ?? ToolchainRegistry()
    }

    func save(_ layout: EnvironmentLayout) throws {
        try layout.make(layout.toolchains)
        try JSONFile.write(self, to: layout.toolchainRegistry)
    }
}
