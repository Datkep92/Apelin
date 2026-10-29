import ApelinCore
@testable import ApelinEnvironment
import ApelinGit
@testable import ApelinProtocol
import Foundation
import XCTest

/// Feedback filed on Apelin's own repository: GitHub's API answered by a
/// fake, the github.com sign-in in memory, Apelin's Info.plist a file under
/// the install root as the package leaves it.
final class FeedbackTests: XCTestCase {
    /// GitHub's issues endpoint, noting each request.
    final class FakeGitHub: @unchecked Sendable {
        private let lock = NSLock()
        var status = 201
        var message = "Bad credentials"
        private var log: [URLRequest] = []

        var requests: [URLRequest] {
            lock.withLock { log }
        }

        var exchange: GitHubAPI.Exchange {
            { request in self.answer(request) }
        }

        private func answer(_ request: URLRequest) -> (Data, HTTPURLResponse) {
            lock.withLock {
                log.append(request)
                let object: [String: Any] = (200 ..< 300).contains(status)
                    ? ["number": 42, "html_url": "https://github.com/owngoal-dev/Apelin/issues/42"]
                    : ["message": message]
                let data = try! JSONSerialization.data(withJSONObject: object)
                return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
    }

    private static let token = "gho_feedbacktoken0123456789"

    private func service(_ home: TemporaryHome, github: FakeGitHub, signedIn: Bool = true) throws -> FeedbackService {
        let store = MemoryGitCredentialStore()
        if signedIn {
            try store.save(GitCredential(username: "someone", token: Self.token), forHost: "github.com")
        }
        var service = FeedbackService(layout: home.layout, credentials: store)
        service.exchange = github.exchange
        service.hostName = "Adas-iPhone"
        service.osVersion = "17.3.1"
        return service
    }

    /// The app's Info.plist where the package installs it, binary as Xcode
    /// writes it.
    private func installApp(_ installRoot: String, version: Any = "0.2.7", build: Any = "18") throws {
        let app = URL(fileURLWithPath: installRoot).appendingPathComponent("Applications/Apelin.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "wiki.qaq.apelin", "CFBundleShortVersionString": version, "CFBundleVersion": build,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
    }

    func testASendIsOneIssueOnApelinsRepositoryWithTheFooter() async throws {
        let home = try TemporaryHome(self)
        try installApp(home.layout.installRoot)
        let github = FakeGitHub()
        let request = FeedbackSendRequest(title: "  The build log stops early ", body: "It ends before the link step.\n\n")
        let response = try await service(home, github: github).send(request)
        XCTAssertEqual(response, FeedbackSendResponse(number: 42, url: "https://github.com/owngoal-dev/Apelin/issues/42"))

        XCTAssertEqual(github.requests.count, 1)
        let sent = try XCTUnwrap(github.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.absoluteString, "https://api.github.com/repos/owngoal-dev/Apelin/issues")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(Self.token)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: String])
        XCTAssertEqual(Set(body.keys), ["title", "body"], "nothing but the issue")
        XCTAssertEqual(body["title"], "The build log stops early")
        XCTAssertEqual(body["body"], "It ends before the link step.\n\n---\nSent with Apelin 0.2.7 (18) · iOS 17.3.1 · rootless")
    }

    func testTheFooterNamesTheBootstrapAndNoDevice() throws {
        let base = try TemporaryHome(self)
        // roothide keeps mobile's home inside the install root
        let installRoot = base.home.appendingPathComponent("jbroot").path
        let mobile = installRoot + "/var/mobile"
        try FileManager.default.createDirectory(atPath: mobile, withIntermediateDirectories: true)
        let layout = EnvironmentLayout(data: DataFolder(home: mobile), installRoot: installRoot, home: mobile)
        var service = FeedbackService(layout: layout, credentials: MemoryGitCredentialStore())
        service.osVersion = "26.0"
        XCTAssertEqual(service.footer(), "Sent with Apelin (version unknown) · iOS 26.0 · roothide", "no app installed")
        try installApp(installRoot, version: "0.2.7 on Adas-iPhone", build: 18)
        XCTAssertEqual(service.footer(), "Sent with Apelin (version unknown) · iOS 26.0 · roothide", "only a version as Apelin spells one is read")
        try installApp(installRoot, version: "0.2.8", build: "19")
        let footer = service.footer()
        XCTAssertEqual(footer, "Sent with Apelin 0.2.8 (19) · iOS 26.0 · roothide")
        var machine = [CChar](repeating: 0, count: 256)
        var size = machine.count
        if sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 {
            XCTAssertFalse(footer.contains(String(cString: machine)), "the model is no part of it")
        }
    }

    func testWithoutASignInItSaysSoAndAsksNothingOfGitHub() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        do {
            _ = try await service(home, github: github, signedIn: false).send(FeedbackSendRequest(title: "Title", body: "Body"))
            XCTFail("sent without a sign-in")
        } catch let error as ApelinError {
            XCTAssertEqual(error.code, .denied)
            XCTAssertEqual(error.reason, .authenticationRequired)
            XCTAssertTrue(error.message.contains("Settings ▸ Git"), error.message)
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testGitHubsRefusalsNeverQuoteTheToken() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        github.status = 401
        let feedback = FeedbackSendRequest(title: "Title", body: "Body")
        do {
            _ = try await service(home, github: github).send(feedback)
            XCTFail("a refused sign-in went through")
        } catch let error as ApelinError {
            XCTAssertEqual(error.reason, .authenticationRequired, "a revoked sign-in is one to make again")
            XCTAssertFalse(error.description.contains(Self.token))
        }
        github.status = 410
        github.message = "Issues are disabled for this repo"
        do {
            _ = try await service(home, github: github).send(feedback)
            XCTFail("a refusal went through")
        } catch let error as ApelinError {
            XCTAssertNil(error.reason)
            XCTAssertTrue(error.message.contains("Issues are disabled"), error.message)
            XCTAssertFalse(error.description.contains(Self.token))
        }
    }

    func testARefusedTextReachesNobody() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        // Signed out too: the text is refused before the sign-in is read.
        let service = try service(home, github: github, signedIn: false)
        let refused: [FeedbackSendRequest] = [
            FeedbackSendRequest(title: "", body: "Body"),
            FeedbackSendRequest(title: "Two\nlines", body: "Body"),
            FeedbackSendRequest(title: String(repeating: "a", count: 121), body: "Body"),
            FeedbackSendRequest(title: "Title", body: String(repeating: "a", count: 16 * 1024 + 1)),
            FeedbackSendRequest(title: "Title", body: "Saved in /var/mobile/Documents/wiki.qaq.apelin/Projects/Secret"),
            FeedbackSendRequest(title: "Title", body: "Saved in \(home.home.path)/Projects"),
            FeedbackSendRequest(title: "Title", body: "Built under \(home.layout.installRoot)/usr/lib"),
            FeedbackSendRequest(title: "Title", body: "From 192.168.1.20"),
            FeedbackSendRequest(title: "Title", body: "It is Adas-iPhone that fails"),
            FeedbackSendRequest(title: "Title", body: "UDID 00008030-00112233445566AA"),
            FeedbackSendRequest(title: "Title", body: "token ghp_" + String(repeating: "A1b2", count: 9)),
            FeedbackSendRequest(title: "Title", body: "the saved one, \(Self.token)"),
        ]
        for request in refused {
            do {
                _ = try await service.send(request)
                XCTFail("sent: \(request.title) / \(request.body.prefix(40))")
            } catch let error as ApelinError {
                XCTAssertEqual(error.code, .badRequest, error.message)
                XCTAssertFalse(error.message.contains("Adas-iPhone") || error.message.contains("192.168"), error.message)
            }
        }
        XCTAssertTrue(github.requests.isEmpty)
    }

    func testTheWorkerServesIt() async throws {
        let home = try TemporaryHome(self)
        let github = FakeGitHub()
        let worker = EnvironmentWorker(layout: home.layout, backend: UnavailableToolchainBackend(), installer: FakeInstaller()) { _, _, _ in }
        worker.feedback = try service(home, github: github)
        let request = FeedbackSendRequest(title: "Title", body: "Body")
        let (reply, _) = try await worker.handle(ChannelRequest(request: WireRequest(request), descriptors: [], taskID: nil))
        let response = try JSONCoding.decode(FeedbackSendResponse.self, from: reply.result.get())
        XCTAssertEqual(response.number, 42)
        XCTAssertEqual(github.requests.count, 1)
    }
}
