import Foundation

// Settings ▸ Logs lists Dog's journals: regular `Dog_` … `.log` files only,
// newest launch first, undated names last, nothing followed through a link.

func require(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(1)
    }
}

let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("apelin-journal-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }

func write(_ name: String, _ text: String) throws {
    try Data(text.utf8).write(to: directory.appendingPathComponent(name))
}

try write("Dog_2026-10-20_10-00-00_AAAAAAAA.log", "a")
try write("Dog_2026-10-22_09-30-00_BBBBBBBB.log", "bbb")
try write("Dog_2026-10-21_23-59-59_CCCCCCCC.log", "cc")
try write("Dog_undated.log", "dddd")
try write("notes.txt", "not a journal")
try write("Dog_2026-10-23_00-00-00_DDDDDDDD.txt", "not a journal either")
try FileManager.default.createSymbolicLink(
    at: directory.appendingPathComponent("Dog_2026-10-24_00-00-00_EEEEEEEE.log"),
    withDestinationURL: directory.appendingPathComponent("Dog_2026-10-20_10-00-00_AAAAAAAA.log"),
)
try FileManager.default.createDirectory(
    at: directory.appendingPathComponent("Dog_2026-10-25_00-00-00_FFFFFFFF.log"),
    withIntermediateDirectories: false,
)

let files = JournalFiles.list(in: directory)
require(
    files.map(\.name) == [
        "Dog_2026-10-22_09-30-00_BBBBBBBB.log",
        "Dog_2026-10-21_23-59-59_CCCCCCCC.log",
        "Dog_2026-10-20_10-00-00_AAAAAAAA.log",
        "Dog_undated.log",
    ],
    "newest launch first, undated last, only regular Dog_….log files: \(files.map(\.name))",
)
require(files.map(\.size) == [3, 2, 1, 4], "each file's size")
let newest = Calendar(identifier: .gregorian).dateComponents(
    [.year, .month, .day, .hour, .minute, .second],
    from: files[0].started ?? .distantPast,
)
require(
    (newest.year, newest.month, newest.day, newest.hour, newest.minute, newest.second) == (2026, 10, 22, 9, 30, 0),
    "the launch is read off the name, in local time",
)
require(files[3].started == nil, "a name Dog did not date has no launch")
require(JournalFiles.started(fromName: "Dog_2026-13-40_99-99-99_AAAAAAAA.log") == nil, "an impossible date reads as none")
require(JournalFiles.list(in: directory.appendingPathComponent("missing")).isEmpty, "a missing folder lists nothing")
print("ok: the journal list (Dog's files only, newest launch first, links not followed)")
