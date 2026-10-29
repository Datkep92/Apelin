import ApelinCore
import ApelinProtocol
import Darwin
import Foundation

/// Feedback filed as a public issue on Apelin's own repository
/// (`FeedbackSendRequest`), with the github.com sign-in the user made in
/// Settings ▸ Git. The title and body are checked by `FeedbackRules` —
/// against this device's own home, install root and host name too — before
/// the sign-in is looked at, so a refused text reaches nobody. The footer
/// is written here, from Apelin's own Info.plist, the iOS version and the
/// bootstrap; nothing the caller sent goes into it.
public struct FeedbackService: Sendable {
    let layout: EnvironmentLayout
    let credentials: any GitCredentialStore
    /// GitHub's API; a test answers for it.
    var exchange: GitHubAPI.Exchange = GitHubAPI.live
    /// What the device calls itself on the network, which no report names.
    var hostName: String? = Self.currentHostName()
    var osVersion = Self.currentOSVersion()

    static let maximumInfoPlistBytes = 1 << 20

    public init(layout: EnvironmentLayout, credentials: any GitCredentialStore) {
        self.layout = layout
        self.credentials = credentials
    }

    public func send(_ request: FeedbackSendRequest) async throws -> FeedbackSendResponse {
        let title = request.title.trimmingCharacters(in: .whitespaces)
        if let problem = FeedbackRules.problem(
            title: title,
            body: request.body,
            paths: privatePaths,
            names: hostName.map { [$0] } ?? [],
        ) {
            throw ApelinError(.badRequest, problem)
        }
        let api = try GitHubAPI.signedIn(credentials, exchange: exchange)
        let issue = try await api.createIssue(
            FeedbackRules.repository,
            title: title,
            body: FeedbackRules.issueBody(request.body, footer: footer()),
        )
        return FeedbackSendResponse(number: issue.number, url: issue.htmlURL)
    }

    func footer() -> String {
        let version = appVersion()
        return FeedbackRules.footer(
            appVersion: version.short,
            appBuild: version.build,
            osVersion: osVersion,
            bootstrap: BuildBootstrap.resolve(installRoot: layout.installRoot, home: layout.home),
        )
    }

    /// Mobile's home and the install root, as the host gave them and
    /// canonical.
    private var privatePaths: [String] {
        let paths = [layout.home, layout.installRoot]
        return paths + paths.compactMap(CanonicalPath.resolve)
    }

    /// The marketing version and build of the app apelind authenticates,
    /// `<install root>/Applications/Apelin.app`, read only from inside the
    /// install root; nil for one that does not read.
    func appVersion() -> (short: String?, build: String?) {
        guard let root = CanonicalPath.resolve(layout.installRoot),
              let data = BoundedFile.read(
                  layout.installRoot + "/Applications/Apelin.app/Info.plist",
                  inside: root,
                  limit: Self.maximumInfoPlistBytes,
              ),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil) }
        return (Self.versionText(plist["CFBundleShortVersionString"]), Self.versionText(plist["CFBundleVersion"]))
    }

    /// A version as Apelin spells one, else nil: nothing else reaches the
    /// issue from the file.
    static func versionText(_ value: Any?) -> String? {
        guard let text = value as? String, (1 ... 32).contains(text.count),
              text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) })
        else { return nil }
        return text
    }

    /// `17.3.1`, or `26.0` with no patch.
    static func currentOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var text = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion != 0 {
            text += ".\(version.patchVersion)"
        }
        return text
    }

    static func currentHostName() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return nil }
        var name = String(cString: buffer)
        if name.lowercased().hasSuffix(".local") {
            name.removeLast(".local".count)
        }
        return name.isEmpty ? nil : name
    }
}
