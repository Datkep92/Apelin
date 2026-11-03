import ApelinCore
import ApelinProtocol
import Dog

/// Writes `ScreenActionLog`'s lines to the launch journal beside the app's
/// own, so Settings ▸ Logs shows what an agent did to another app and what
/// went wrong while it did: the journal mirrors every line to the unified
/// log too (`com.lakr233.dog`), which is the only copy that outlives the
/// launch.
enum ScreenActionJournal {
    static func note(_ events: [TaskEvent]) {
        for line in ScreenActionLog.lines(in: events) {
            Dog.shared.join(line.category, line.text, level: line.isProblem ? .warning : .info)
        }
    }
}