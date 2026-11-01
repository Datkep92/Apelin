import Foundation
import Network
import UIKit

/// Built-in Google OAuth 2.0 authorization-code flow using Firebase CLI's public
/// client ID/secret and a temporary localhost callback server, so Google sign-in
/// works without the user creating their own Google Cloud OAuth client.
struct GoogleOAuthFlow {
    static let clientID = "563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com"
    static let clientSecret = "j9iVZfS8kkCEFUPaAeJV0sAi"
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    enum Failure: Error, LocalizedError {
        case noPort
        case badURL
        case noCode
        case stateMismatch
        case noToken
        case unreadable
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .noPort: return "Could not open a local callback port."
            case .badURL: return "Could not build the Google sign-in URL."
            case .noCode: return "Google did not return an authorization code."
            case .stateMismatch: return "The sign-in state did not match."
            case .noToken: return "Google did not return an access token."
            case .unreadable: return "Google's answer could not be read."
            case .refused(let reason): return "Google refused the sign-in: \(reason)"
            }
        }
    }

    static func signIn(scopes: [String] = GoogleDeviceFlow.defaultScopes) async throws -> String {
        let bgTask = await MainActor.run { () -> UIBackgroundTaskIdentifier in
            UIApplication.shared.beginBackgroundTask(withName: "GoogleOAuth") {}
        }
        defer {
            if bgTask != .invalid {
                Task { @MainActor in UIApplication.shared.endBackgroundTask(bgTask) }
            }
        }

        let listener = try await startListener()
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw Failure.noPort
        }
        let redirectURI = "http://127.0.0.1:\(port)"
        let state = UUID().uuidString

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else {
            listener.cancel()
            throw Failure.badURL
        }
        await MainActor.run { UIApplication.shared.open(url) }

        let code: String
        do {
            code = try await waitForCallback(listener: listener, expectedState: state)
        } catch {
            listener.cancel()
            throw error
        }
        listener.cancel()
        return try await exchangeCode(code: code, redirectURI: redirectURI)
    }

    private static func startListener() async throws -> NWListener {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
        guard listener.port != nil else { throw Failure.noPort }
        return listener
    }

    private static func waitForCallback(listener: NWListener, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                    guard let data = data, let request = String(data: data, encoding: .utf8) else {
                        resumeOnce(.failure(Failure.unreadable))
                        connection.cancel()
                        return
                    }
                    let lines = request.split(separator: "\r\n", omittingEmptySubsequences: false)
                    let requestLine = lines.first.map(String.init) ?? ""
                    let parts = requestLine.split(separator: " ")
                    let path = parts.count >= 2 ? String(parts[1]) : "/"
                    let components = URLComponents(string: "http://127.0.0.1\(path)")
                    let code = components?.queryItems?.first(where: { $0.name == "code" })?.value
                    let state = components?.queryItems?.first(where: { $0.name == "state" })?.value
                    let errorParam = components?.queryItems?.first(where: { $0.name == "error" })?.value

                    let html = "<!doctype html><html><body><p>Signed in. You can close this page.</p></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })

                    if let errorParam = errorParam, !errorParam.isEmpty {
                        resumeOnce(.failure(Failure.refused(errorParam)))
                    } else if state != expectedState {
                        resumeOnce(.failure(Failure.stateMismatch))
                    } else if let code = code, !code.isEmpty {
                        resumeOnce(.success(code))
                    } else {
                        resumeOnce(.failure(Failure.noCode))
                    }
                }
            }
        }
    }

    private static func exchangeCode(code: String, redirectURI: String) async throws -> String {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ]
        request.httpBody = Data(GitHubDeviceFlow.formBody(body).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let error = json["error"] as? String {
            throw Failure.refused(json["error_description"] as? String ?? error)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let token = json["access_token"] as? String, !token.isEmpty else {
            throw Failure.noToken
        }
        return token
    }
}

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
