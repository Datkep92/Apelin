import ApelinCore
import Foundation

/// The data folder the package's postinst made, `~/Documents/wiki.qaq.apelin`
/// on mobile's home — the one apelind, the session host and the workers all
/// read. The system may instead have given the app a data container, so
/// `NSHomeDirectory()` answers inside `Containers/Data/Application/<uuid>` and
/// two homes grew apart: chats and the journal saved on the container side
/// were missing on the other, and the project list came up empty. On the
/// first launch this brings the container's data into mobile's home: copied
/// only where the target has nothing yet, never replacing a file, so nothing
/// written by either side is lost. A marker keeps it to a one-time pass.
enum LegacyHome {
    static func bringDataAcross() {
        let folder = DataFolder.app
        guard let legacy = legacyFolder() else { return }
        try? FileManager.default.createDirectory(at: folder.root, withIntermediateDirectories: true)
        let marker = folder.root.appendingPathComponent(".brought-from-container")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }

        // The app's own stores: chats with the records and their uploads, the
        // journal, and saved stories.
        for name in ["Chats", "Journal", "Stories"] {
            copyMissing(
                from: legacy.appendingPathComponent(name),
                into: folder.root.appendingPathComponent(name)
            )
        }
        // A project comes across whole, or not at all: only a directory that
        // is itself an Apelin project (its `apelin-project.json` is there)
        // and that has never been here, so a stray folder is not carried.
        copyProjects(from: legacy, into: folder.root)
        _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
        NSLog("Apelin: the container's data was brought into \(folder.root.path)")
    }

    /// The container's own data folder when the system gave the app one,
    /// `nil` otherwise: on a home already in mobile's own there is nothing
    /// to bring across. The container is where earlier builds of the app
    /// saved, and it stays under mobile's home, so the two sides are the
    /// app's container and `DataFolder.app`, never a folder of another user.
    private static func legacyFolder() -> URL? {
        let home = NSHomeDirectory()
        guard home.contains("/Containers/Data/Application/") else { return nil }
        guard home.hasPrefix("/var/mobile/") || home.hasPrefix("/private/var/mobile/") else { return nil }
        let root = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(DataFolder.bundleIdentifier)
        return FileManager.default.fileExists(atPath: root.path) ? root : nil
    }

    private static func copyMissing(from source: URL, into target: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: source.path) else { return }
        // The target's levels come first: a store copied whole into a folder
        // that is not there yet would fail file by file otherwise.
        if !fileManager.fileExists(atPath: target.path) {
            try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: from.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if !fileManager.fileExists(atPath: to.path) {
                    try? fileManager.createDirectory(at: to, withIntermediateDirectories: true)
                }
                copyMissing(from: from, into: to)
            } else if !fileManager.fileExists(atPath: to.path) {
                try? fileManager.copyItem(at: from, to: to)
            }
        }
    }

    private static func copyProjects(from legacy: URL, into home: URL) {
        let fileManager = FileManager.default
        let source = legacy.appendingPathComponent("Projects")
        let target = home.appendingPathComponent("Projects")
        guard let names = try? fileManager.contentsOfDirectory(atPath: source.path) else { return }
        for name in names {
            let from = source.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: from.appendingPathComponent("apelin-project.json").path)
            else { continue }
            let to = target.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: to.path) else { continue }
            try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try? fileManager.copyItem(at: from, to: to)
        }
    }
}
