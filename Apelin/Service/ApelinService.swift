import ApelinCore
import ApelinProtocol
import Foundation

/// The app's binding of `ApelinService`, the one surface the console, the UI
/// and (from apelin-agent, over its channel) the agent's tools call. The
/// methods are in Packages/ApelinKit/Sources/ApelinProtocol/Operations; this
/// only says how the app reaches apelind.
extension ApelinService {
    /// Through apelind over XPC.
    static let app = ApelinService(transport: DaemonClient.shared)
}

extension DataFolder {
    /// `~/Documents/wiki.qaq.apelin` as the app sees it: the app has no
    /// container, so its home is mobile's.
    static let app = DataFolder(home: mobileHome)

    /// Mobile's home as the session host and the package see it:
    /// `<jbroot>/var/mobile` on roothide, `/var/mobile` on rootless.
    /// `NSHomeDirectory()` answers the system's `/var/mobile` on both, and on
    /// roothide that is a different folder from the one the postinst made and
    /// the workers write into, so a script dropped in the inbox was never
    /// seen. The bootstrap is recognised off the bundle's own path, the way
    /// the session host recognises it off its own.
    private static var mobileHome: String {
        if let root = RoothideRoot.containing(Bundle.main.bundlePath) {
            return root + "/var/mobile"
        }
        let home = NSHomeDirectory()
        // An app the system gave a data container answers a home inside
        // `Containers/Data/Application/<uuid>`, a different folder from the
        // one the postinst made and everything else reads, so the container
        // is crossed and mobile's own home is used (the data saved on the
        // container side comes across on this launch, see `LegacyHome`).
        if let range = home.range(of: "/Containers/Data/Application/") {
            let home = String(home[..<range.lowerBound])
            if home.hasSuffix("/var/mobile") { return home }
        }
        return home
    }
}
