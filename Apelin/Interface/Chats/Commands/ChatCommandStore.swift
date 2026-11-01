import Foundation

/// A chat slash command loaded from `~/Documents/wiki.qaq.apelin/commands/`.
struct ChatCommand {
    let name: String
    let description: String
    let template: String

    /// Expands the template with the user's content.
    func expand(content: String) -> String {
        template.replacingOccurrences(of: "{{content}}", with: content)
    }
}

/// Loads, lists and expands slash commands stored globally.
final class ChatCommandStore {
    static let shared = ChatCommandStore()

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            self.directory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent("wiki.qaq.apelin", isDirectory: true)
                .appendingPathComponent("commands", isDirectory: true)
        }
    }

    /// Ensures the commands directory exists and ships default commands if empty.
    func ensureDefaults() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let hasCommands = existing.contains { $0.hasSuffix(".md") }
        guard !hasCommands else { return }
        for (name, content) in Self.defaultCommands {
            let url = directory.appendingPathComponent("\(name).md")
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// All available commands, sorted by name.
    func all() -> [ChatCommand] {
        ensureDefaults()
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var result: [ChatCommand] = []
        for file in files where file.pathExtension == "md" {
            if let command = parse(file) { result.append(command) }
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Finds a command by name.
    func find(_ name: String) -> ChatCommand? {
        all().first { $0.name == name }
    }

    /// Expands a slash command in text. Returns (expandedText, commandName) if matched.
    func expand(_ text: String) -> (String, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        // parse: /name rest...
        let withoutSlash = String(trimmed.dropFirst())
        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }
        let name = String(first).lowercased()
        guard let command = find(name) else { return nil }
        let content = parts.count > 1 ? String(parts[1]) : ""
        return (command.expand(content: content), name)
    }

    // MARK: - Parsing

    private func parse(_ url: URL) -> ChatCommand? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Split frontmatter
        let lines = raw.components(separatedBy: "\n")
        var name: String?
        var description = ""
        var templateStart = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            while i < lines.count {
                let line = lines[i]
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    templateStart = i + 1
                    break
                }
                let kv = line.split(separator: ":", maxSplits: 1)
                if kv.count == 2 {
                    let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                    let val = kv[1].trimmingCharacters(in: .whitespaces)
                    if key == "name" { name = val }
                    if key == "description" { description = val }
                }
                i += 1
            }
        } else {
            // No frontmatter: use filename as name
            name = url.deletingPathExtension().lastPathComponent
            templateStart = 0
        }
        guard let cmdName = name, !cmdName.isEmpty else {
            name = url.deletingPathExtension().lastPathComponent
            guard let n = name, !n.isEmpty else { return nil }
            // fallback
            let template = lines.joined(separator: "\n")
            return ChatCommand(name: n, description: description, template: template)
        }
        let template = lines[templateStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatCommand(name: cmdName, description: description, template: template)
    }

    // MARK: - Defaults

    static let defaultCommands: [(String, String)] = [
        ("plan", """
        ---
        name: plan
        description: Lập kế hoạch chi tiết trước khi code
        ---
        Bạn là planner. Hãy lập kế hoạch chi tiết cho task sau, KHÔNG viết code, chỉ phân tích và đề xuất các bước:

        {{content}}
        """),
        ("build", """
        ---
        name: build
        description: Hướng dẫn build và kiểm tra sản phẩm
        ---
        Hãy thực hiện build và kiểm tra sản phẩm theo task sau, báo cáo lỗi nếu có:

        {{content}}
        """),
        ("review", """
        ---
        name: review
        description: Review code theo best practices
        ---
        Hãy review code sau theo best practices, chỉ ra vấn đề và đề xuất cải thiện:

        {{content}}
        """),
        ("explain", """
        ---
        name: explain
        description: Giải thích code hoặc khái niệm
        ---
        Hãy giải thích rõ ràng, dễ hiểu cho người không chuyên về code:

        {{content}}
        """),
        ("fix", """
        ---
        name: fix
        description: Tìm và sửa lỗi
        ---
        Hãy tìm nguyên nhân gốc rễ và sửa lỗi sau, kiểm tra regression:

        {{content}}
        """),
    ]
}
""", path: "Apelin/Interface/Chats/Commands/ChatCommand.swift", reason: "Tạo model và store cho slash commands")