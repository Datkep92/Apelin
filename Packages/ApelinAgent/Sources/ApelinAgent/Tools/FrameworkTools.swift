import Foundation
import KWWKAI

/// `analyze_framework` and `framework_header`: read a registered SDK's
/// `.tbd` stubs and headers directly, as mobile. The SDK root comes from the
/// host; every read stays inside it.
struct FrameworkTools: Sendable {
    let sdk: ScopedRoot

    func analyze(_ arguments: JSONValue) throws -> String {
        let name = try frameworkName(arguments)
        let isPrivate = arguments.argBool("private") ?? false
        let filter = arguments.argString("symbol_filter")
        let framework = try frameworkDirectory(name, isPrivate: isPrivate)
        let tbdPath = try sdk.resolveExisting("\(framework)/\(name).tbd")
        let text = try readSDKText(tbdPath, limit: 32 * 1024 * 1024)
        let stub = TBDStub.parse(text)

        var lines = ["\(name).framework (\(isPrivate ? "private" : "public"))"]
        if let installName = stub.installName {
            lines.append("install name: \(installName)")
        }
        if !stub.targets.isEmpty {
            lines.append("targets: \(stub.targets.joined(separator: ", "))")
        }
        if let version = stub.currentVersion {
            lines.append("current version: \(version)")
        }
        if !stub.reexports.isEmpty {
            lines.append("re-exports: \(stub.reexports.joined(separator: ", "))")
        }

        let symbols = stub.symbols.filter { filter == nil || $0.localizedCaseInsensitiveContains(filter!) }
        let classes = stub.objcClasses.filter { filter == nil || $0.localizedCaseInsensitiveContains(filter!) }
        lines.append(
            "exported symbols: \(stub.symbols.count)\(filter.map { ", \(symbols.count) matching '\($0)'" } ?? "")",
        )
        lines.append(contentsOf: symbols.prefix(300).map { "  \($0)" })
        if symbols.count > 300 {
            lines.append("  … \(symbols.count - 300) more; narrow with symbol_filter")
        }
        lines.append(
            "Objective-C classes: \(stub.objcClasses.count)\(filter.map { ", \(classes.count) matching '\($0)'" } ?? "")",
        )
        lines.append(contentsOf: classes.prefix(300).map { "  \($0)" })
        if classes.count > 300 {
            lines.append("  … \(classes.count - 300) more")
        }

        let headers = headerNames(framework)
        lines.append("headers: \(headers.count)")
        lines.append(contentsOf: headers.prefix(200).map { "  \($0)" })
        return lines.joined(separator: "\n")
    }

    func header(_ arguments: JSONValue) throws -> String {
        let name = try frameworkName(arguments)
        let isPrivate = arguments.argBool("private") ?? false
        let framework = try frameworkDirectory(name, isPrivate: isPrivate)
        guard let header = arguments.argString("header") else {
            let headers = headerNames(framework)
            return headers.isEmpty ? "\(name).framework has no headers in this SDK" : headers.joined(separator: "\n")
        }
        guard !header.contains("/"), !header.contains("\0"), !header.hasPrefix(".") else {
            throw ToolArgumentError("header must be a file name")
        }
        let path = try sdk.resolveExisting("\(framework)/Headers/\(header)")
        return try readSDKText(path, limit: 2 * 1024 * 1024)
    }

    // MARK: - Helpers

    private func frameworkName(_ arguments: JSONValue) throws -> String {
        var name = try arguments.requireString("framework")
        if name.hasSuffix(".framework") {
            name = String(name.dropLast(".framework".count))
        }
        guard !name.isEmpty, !name.contains("/"), !name.contains("\0"), !name.hasPrefix(".") else {
            throw ToolArgumentError("framework must be a name like UIKit")
        }
        return name
    }

    private func frameworkDirectory(_ name: String, isPrivate: Bool) throws -> String {
        let relative = "System/Library/\(isPrivate ? "PrivateFrameworks" : "Frameworks")/\(name).framework"
        let real = try sdk.resolveExisting(relative)
        return sdk.relative(real)
    }

    private func headerNames(_ framework: String) -> [String] {
        guard let headers = try? sdk.resolveExisting("\(framework)/Headers"),
              let entries = try? FileManager.default.contentsOfDirectory(atPath: headers) else { return [] }
        return entries.filter { $0.hasSuffix(".h") }.sorted()
    }

    private func readSDKText(_ canonical: String, limit: Int) throws -> String {
        guard sdk.contains(canonical) else { throw PathPolicyError.outsideRoot(canonical) }
        let url = URL(fileURLWithPath: canonical)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw PathPolicyError.notAFile(sdk.relative(canonical)) }
        guard (values.fileSize ?? 0) <= limit else {
            throw ToolArgumentError("\(sdk.relative(canonical)) is too large")
        }
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
    }
}

/// The parts of a text-based stub (`.tbd`, v3/v4 YAML or v5 JSON) the agent
/// needs.
struct TBDStub: Equatable {
    var installName: String?
    var currentVersion: String?
    var targets: [String] = []
    var reexports: [String] = []
    var symbols: [String] = []
    var objcClasses: [String] = []

    static func parse(_ text: String) -> TBDStub {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let stub = parseJSON(trimmed) {
            return stub
        }
        return parseYAML(text)
    }

    private static func parseYAML(_ text: String) -> TBDStub {
        var stub = TBDStub()
        stub.installName = scalar("install-name", in: text)
        stub.currentVersion = scalar("current-version", in: text)
        stub.targets = unique(lists("targets", in: text))
        if stub.targets.isEmpty {
            stub.targets = unique(lists("archs", in: text))
        }
        stub.reexports = unique(
            lists("re-exports", in: text) + lists("reexported-libraries", in: text).filter { $0.hasPrefix("/") },
        )
        // Only the exports sections, not undefineds.
        let exports = sections(of: text, named: ["exports:", "reexports:"])
        stub.symbols = unique(
            lists("symbols", in: exports)
                + lists("weak-symbols", in: exports)
                + lists("thread-local-symbols", in: exports),
        )
        stub.objcClasses = unique(lists("objc-classes", in: exports))
        return stub
    }

    private static func parseJSON(_ text: String) -> TBDStub? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return nil
        }
        let library = (object["main_library"] as? [String: Any]) ?? object
        var stub = TBDStub()
        stub.installName = ((library["install_names"] as? [[String: Any]])?.first?["name"]) as? String
        stub.currentVersion = ((library["current_versions"] as? [[String: Any]])?.first?["version"]) as? String
        stub.targets = ((library["target_info"] as? [[String: Any]]) ?? []).compactMap { $0["target"] as? String }
        stub.reexports = ((library["reexported_libraries"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["names"] as? [String]) ?? [] }
        var symbols: [String] = []
        var classes: [String] = []
        for entry in (library["exported_symbols"] as? [[String: Any]]) ?? [] {
            for key in ["data", "text"] {
                guard let group = entry[key] as? [String: Any] else { continue }
                symbols += (group["global"] as? [String]) ?? []
                symbols += (group["weak"] as? [String]) ?? []
                classes += (group["objc_class"] as? [String]) ?? []
            }
        }
        stub.symbols = unique(symbols)
        stub.objcClasses = unique(classes)
        return stub
    }

    /// The text from each `name` line to the next top-level key.
    private static func sections(of text: String, named names: [String]) -> String {
        var output = ""
        var inside = false
        for line in text.components(separatedBy: "\n") {
            let isTopLevel = !line.hasPrefix(" ") && !line.hasPrefix("-") && line.contains(":")
            if isTopLevel {
                inside = names.contains { line.hasPrefix($0) }
            }
            if inside {
                output += line + "\n"
            }
        }
        return output
    }

    private static func scalar(_ key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            guard stripped.hasPrefix("\(key):") else { continue }
            let value = stripped.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            return unquote(value)
        }
        return nil
    }

    /// Every `[ … ]` list that follows `key:`, across lines.
    private static func lists(_ key: String, in text: String) -> [String] {
        var values: [String] = []
        var search = text.startIndex
        let needle = "\(key):"
        while let found = text.range(of: needle, range: search ..< text.endIndex) {
            // Must be a whole key: preceded by start, space, '-' or newline.
            if found.lowerBound > text.startIndex {
                let before = text[text.index(before: found.lowerBound)]
                if !(before == " " || before == "\n" || before == "-" || before == "\t") {
                    search = found.upperBound
                    continue
                }
            }
            guard let open = text[found.upperBound...].firstIndex(where: { !$0.isWhitespace }), text[open] == "[",
                  let close = text[open...].firstIndex(of: "]")
            else {
                search = found.upperBound
                continue
            }
            let body = text[text.index(after: open) ..< close]
            values += body.split(separator: ",")
                .map { unquote($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty }
            search = close
        }
        return values
    }

    private static func unquote(_ value: String) -> String {
        var value = value
        if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
