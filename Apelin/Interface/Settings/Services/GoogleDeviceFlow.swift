import Foundation

/// Google's OAuth 2.0 device authorization flow (RFC 8628), used for
/// Firebase and Google Apps Script. The user enters a code on Google's page
/// and approves; the app polls meanwhile. Requires a Google Cloud project
/// with an OAuth client of type "TVs and Limited Input devices" — its client
/// ID is stored per project so each Apelin project can map to its own Google
/// Cloud project.
struct GoogleDeviceFlow: Sendable {
    let clientID: String

    static let deviceCodeURL = URL(string: "https://oauth2.googleapis.com/device/code")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    /// Default scopes for Firebase + Google Apps Script management.
    static let defaultScopes = [
        "https://www.googleapis.com/auth/firebase",
        "https://www.googleapis.com/auth/script.projects",
        "https://www.googleapis.com/auth/cloud-platform",
    ]

    struct Code: Equatable, Sendable {
        let userCode: String
        let verificationURL: URL
        let deviceCode: String
        let expiresIn: TimeInterval
        let interval: TimeInterval
    }

    enum Failure: Error, Equatable {
        case denied
        case expired
        case refused(String)
        case unreadable
    }

    let exchange: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let wait: @Sendable (TimeInterval) async throws -> Void

    static func live(clientID: String) -> GoogleDeviceFlow {
        GoogleDeviceFlow(
            clientID: clientID,
            exchange: { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw Failure.unreadable }
                return (data, response)
            },
            wait: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
        )
    }

    init(clientID: String, exchange: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse), wait: @escaping @Sendable (TimeInterval) async throws -> Void) {
        self.clientID = clientID
        self.exchange = exchange
        self.wait = wait
    }

    func requestCode(scopes: [String] = GoogleDeviceFlow.defaultScopes) async throws -> Code {
        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": clientID,
            "scope": scopes.joined(separator: " "),
        ]
        request.httpBody = Data(GitHubDeviceFlow.formBody(body).utf8)
        let (data, response) = try await exchange(request)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = object["error"] as? String {
            throw Failure.refused(object["error_description"] as? String ?? error)
        }
        guard response.statusCode == 200,
              let userCode = object["user_code"] as? String, !userCode.isEmpty,
              let deviceCode = object["device_code"] as? String, !deviceCode.isEmpty,
              let page = (object["verification_uri"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https",
              let expiresIn = object["expires_in"] as? Double,
              let interval = object["interval"] as? Double
        else { throw Failure.unreadable }
        return Code(
            userCode: userCode,
            verificationURL: page,
            deviceCode: deviceCode,
            expiresIn: expiresIn,
            interval: max(interval, 1),
        )
    }

    func token(for code: Code) async throws -> String {
        var interval = code.interval
        var margin = 1.2
        var waited: TimeInterval = 0
        while true {
            let pause = interval * margin
            guard waited + pause < code.expiresIn else { throw Failure.expired }
            try await wait(pause)
            waited += pause
            var request = URLRequest(url: Self.tokenURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ]
            request.httpBody = Data(GitHubDeviceFlow.formBody(body).utf8)
            let (data, response) = try await exchange(request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let token = object["access_token"] as? String, !token.isEmpty {
                return token
            }
            switch object["error"] as? String {
            case "authorization_pending":
                continue
            case "slow_down":
                interval = (object["interval"] as? Double).map { max($0, 1) } ?? interval + 5
                margin = 1.4
            case "expired_token":
                throw Failure.expired
            case "access_denied":
                throw Failure.denied
            case let error?:
                throw Failure.refused(object["error_description"] as? String ?? error)
            case nil:
                throw Failure.unreadable
            }
        }
    }
}
