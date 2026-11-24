import Foundation
import KWWKAI

/// apelin_generate_image: create pictures with the provider Apelin is already
/// signed in to. The endpoint, the key and the token are injected by the
/// session; the model only names the prompt, the image model and the optional
/// size, quality and style. Nothing secret is ever read from a tool argument,
/// written to the approval card, or logged.
///
/// The wire is the OpenAI-compatible Images API (`POST /v1/images/generations`)
/// with a JSON body. A provider that answers with base64 data needs no second
/// request; one that answers with a URL is fetched here and shown as a picture
/// in the same turn.
struct ImageGeneration: Sendable {
    /// How many pictures one call may ask for. The API's own bound is ten;
    /// four keeps the reply small enough to show in a transcript.
    static let maximumImages = 4
    /// Image models take longer than a chat completion.
    static let timeoutSeconds = 180
    static let maximumBodyBytes = 8 * 1024 * 1024

    /// The saved sign-in, resolved when the call runs so a refreshed token
    /// is used. Never read from the model's arguments or shown on a card.
    struct Credential: Sendable {
        let endpoint: URL
        let headerName: String
        let headerValue: String
        let defaultModel: String?

        /// Builds the images endpoint from a saved Base URL. The path is the
        /// canonical Base URL's path plus `/images/generations`, never a
        /// second `/v1` when the saved address already ends in one.
        static func endpoint(baseURL: String) -> URL? {
            guard var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil
            else { return nil }
            let path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            parts.path = "/" + (path.isEmpty ? "v1" : path) + "/images/generations"
            parts.query = nil
            parts.fragment = nil
            return parts.url
        }
    }

    /// The endpoint and the auth header, from the conversation's saved
    /// provider. Nil when the conversation has no sign-in to send with.
    var credential: Credential?
    private let session: URLSession

    init(credential: Credential? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.credential = credential
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(Self.timeoutSeconds)
        configuration.httpAdditionalHeaders = ["User-Agent": "Apelin", "Accept": "application/json"]
        session = URLSession(configuration: configuration)
    }

    /// The arguments the model may choose, all of them ordinary text or
    /// numbers. The key, token and endpoint are deliberately not among them.
    struct Request: Sendable {
        let prompt: String
        let model: String?
        let count: Int
        let size: String?
        let quality: String?
        let style: String?

        static func from(_ arguments: JSONValue) throws -> Request {
            let prompt = try arguments.requireString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { throw ToolArgumentError("prompt is empty") }
            guard prompt.utf8.count <= 4000 else {
                throw ToolArgumentError("prompt is longer than 4000 bytes; shorten it")
            }
            let count = arguments.argInt("n") ?? 1
            guard (1 ... ImageGeneration.maximumImages).contains(count) else {
                throw ToolArgumentError("n must be 1 to \(ImageGeneration.maximumImages)")
            }
            return Request(
                prompt: prompt,
                model: arguments.argString("model").map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
                count: count,
                size: arguments.argString("size"),
                quality: arguments.argString("quality"),
                style: arguments.argString("style"),
            )
        }
    }

    /// What the transcript shows: one text line and the pictures themselves.
    struct Result: Sendable {
        let summary: String
        let images: [GeneratedImage]
    }

    struct GeneratedImage: Sendable {
        let data: Data
        let mimeType: String
        let revisedPrompt: String?
    }

    func generate(_ arguments: JSONValue) async throws -> Result {
        guard let credential else {
            throw ToolArgumentError("no signed-in image provider is available for this conversation; add one in Settings ▸ Model Providers and choose it here")
        }
        let request = try Request.from(arguments)
        var body: [String: Any] = [
            "prompt": request.prompt,
            "n": request.count,
        ]
        if let model = request.model ?? credential.defaultModel {
            body["model"] = model
        }
        if let size = request.size { body["size"] = size }
        if let quality = request.quality { body["quality"] = quality }
        if let style = request.style { body["style"] = style }
        guard let json = try? JSONSerialization.data(withJSONObject: body, options: []) else {
            throw ToolDeniedError(message: "the image request could not be encoded")
        }

        var urlRequest = URLRequest(url: credential.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(credential.headerValue, forHTTPHeaderField: credential.headerName)
        urlRequest.httpBody = json

        let (bytes, response) = try await session.bytes(for: urlRequest)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw ToolDeniedError(message: "the image provider did not answer over HTTP")
        }
        var payload = Data()
        for try await chunk in bytes {
            payload.append(chunk)
            guard payload.count <= Self.maximumBodyBytes else {
                throw ToolDeniedError(message: "the image provider answered with more than \(Self.maximumBodyBytes) bytes")
            }
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let detail = Self.errorMessage(payload)
            throw ToolDeniedError(message: "image generation failed (\(http.statusCode))\(detail.isEmpty ? "" : ": \(detail)")")
        }
        let images = try await Self.decode(payload, session: session)
        guard !images.isEmpty else {
            throw ToolDeniedError(message: "the image provider answered without pictures")
        }
        let names = images.map(\.mimeType).reduce(into: [:]) { $0[$1, default: 0] += 1 }
        let description = names.map { "\($0.value) \($0.key)" }.sorted().joined(separator: ", ")
        return Result(summary: "Generated \(images.count) image(s): \(description).", images: images)
    }

    /// The provider's error text when it sent one; never the request or the
    /// auth header, which could carry the key.
    private static func errorMessage(_ payload: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return payload.count < 200 ? String(data: payload, encoding: .utf8) ?? "" : ""
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return (object["message"] as? String) ?? (object["detail"] as? String) ?? ""
    }

    private static func decode(_ payload: Data, session: URLSession) async throws -> [GeneratedImage] {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let entries = object["data"] as? [[String: Any]]
        else {
            throw ToolDeniedError(message: "the image provider's answer did not read as image data")
        }
        var images: [GeneratedImage] = []
        for entry in entries.prefix(maximumImages) {
            let revised = entry["revised_prompt"] as? String
            if let encoded = entry["b64_json"] as? String,
               let data = Data(base64Encoded: encoded), !data.isEmpty {
                images.append(GeneratedImage(data: data, mimeType: mimeType(of: data), revisedPrompt: revised))
            } else if let address = entry["url"] as? String,
                      let url = URL(string: address),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                do {
                    let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
                    defer { bytes.task.cancel() }
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                    var fetched = Data()
                    for try await chunk in bytes {
                        fetched.append(chunk)
                        guard fetched.count <= maximumBodyBytes else { break }
                    }
                    if !fetched.isEmpty {
                        images.append(GeneratedImage(data: fetched, mimeType: mimeType(of: fetched), revisedPrompt: revised))
                    }
                } catch {
                    continue
                }
            }
        }
        return images
    }

    /// The kind of picture from its first bytes, never its name.
    private static func mimeType(of data: Data) -> String {
        let head = data.prefix(12)
        if head.starts(with: Data([0x89, 0x50, 0x4E, 0x47])) { return "image/png" }
        if head.starts(with: Data([0xFF, 0xD8, 0xFF])) { return "image/jpeg" }
        if head.starts(with: Data("GIF8".utf8)) { return "image/gif" }
        if head.count >= 12, head.starts(with: Data("RIFF".utf8)),
           Data(head[8 ..< 12]) == Data("WEBP".utf8) { return "image/webp" }
        if head.starts(with: Data([0x00, 0x00, 0x01, 0x00])) { return "image/x-icon" }
        return "image/png"
    }
}
