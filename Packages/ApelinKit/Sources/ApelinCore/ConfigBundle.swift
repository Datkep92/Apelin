import CryptoKit
import CommonCrypto
import Foundation

/// The one schema name/version pair the export/import packet speaks. A schema
/// bump is made when a new optional field is NOT enough to describe the data.
public struct ConfigBundleSchema {
    public static let name = "apelin-config-bundle"
    public static let version = "1.0.0"
    public static let supportedArchiveExtensions = ["apelinbak"]
    public static let maximumFiles = 300
    public static let maximumTotalBytes = 32 * 1024 * 1024
    public static let maximumFileBytes = 16 * 1024 * 1024
}

/// A single file held inside a bundle. Paths are always relative to the app
/// data root and contain no selector escape.
public struct ConfigBundleFile: Codable, Equatable, Sendable {
    public let path: String
    public let size: Int
    public let sha256: String
    public let contentBase64: String

    public var data: Data? { Data(base64Encoded: contentBase64) }

    public init(path: String, data: Data) throws {
        try ConfigBundlePath.validate(path)
        guard data.count <= ConfigBundleSchema.maximumFileBytes else { throw ConfigBundleError.fileTooLarge }
        self.path = path
        self.size = data.count
        self.sha256 = ConfigBundleChecksum.sha256(data)
        self.contentBase64 = data.base64EncodedString()
    }

    public init(path: String, size: Int, sha256: String, contentBase64: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.contentBase64 = contentBase64
    }
}

/// Manifest carried inside every bundle. It is compact and safe to show in UI.
public struct ConfigBundleManifest: Codable, Equatable, Sendable {
    public let schemaName: String
    public let schemaVersion: String
    public let createdAt: Date
    public let appVersion: String
    public let buildNumber: String
    public let scopes: [String]
    public let files: [ConfigBundleFile]
    public let hasSecretPack: Bool

    public init(
        createdAt: Date = Date(),
        appVersion: String,
        buildNumber: String,
        scopes: [String],
        files: [ConfigBundleFile],
        hasSecretPack: Bool
    ) {
        self.schemaName = ConfigBundleSchema.name
        self.schemaVersion = ConfigBundleSchema.version
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.scopes = scopes.sorted()
        self.files = files.sorted { $0.path < $1.path }
        self.hasSecretPack = hasSecretPack
    }

    public static func validate(_ manifest: ConfigBundleManifest) throws {
        guard manifest.schemaName == ConfigBundleSchema.name else {
            throw ConfigBundleError.unsupportedSchema
        }
        guard manifest.schemaVersion == ConfigBundleSchema.version else {
            throw ConfigBundleError.unsupportedSchemaVersion
        }
        guard manifest.files.count <= ConfigBundleSchema.maximumFiles else {
            throw ConfigBundleError.tooManyFiles
        }
        var seenPaths = Set<String>()
        var totalBytes = 0
        for file in manifest.files {
            try ConfigBundlePath.validate(file.path)
            try ConfigBundleChecksum.parse(file.size, stored: file.sha256)
            guard file.size <= ConfigBundleSchema.maximumFileBytes else { throw ConfigBundleError.fileTooLarge }
            guard seenPaths.insert(file.path).inserted else { throw ConfigBundleError.invalidPath }
            guard let data = file.data else { throw ConfigBundleError.checksumMismatch }
            guard ConfigBundleChecksum.sha256(data) == file.sha256 else {
                throw ConfigBundleError.checksumMismatch
            }
            totalBytes += file.size
        }
        guard totalBytes <= ConfigBundleSchema.maximumTotalBytes else {
            throw ConfigBundleError.validationFailed("bundle too large")
        }
    }
}

/// A client-side-only secret envelope. Nothing here is a plaintext token.
public struct ConfigBundleSecretPack: Codable, Equatable, Sendable {
    public let salt: Data
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(salt: Data, nonce: Data, ciphertext: Data, tag: Data) {
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

/// A secret entry after successful decryption.
public struct ConfigBundleSecretEntry: Codable, Equatable, Sendable {
    public let providerID: String
    public let token: String

    public init(providerID: String, token: String) {
        self.providerID = providerID
        self.token = token
    }
}

/// Errors reported by validation, encryption and extraction.
public enum ConfigBundleError: Error, Equatable, Sendable {
    case unsupportedSchema
    case unsupportedSchemaVersion
    case checksumMismatch
    case invalidPath
    case pathEscape
    case secretDecryptionFailed
    case secretEncryptionFailed
    case validationFailed(String)
    case archiveDecodeFailed
    case archiveWriteFailed
    case missingFile(String)
    case invalidPassphrase
    case fileTooLarge
    case tooManyFiles
}

/// Fully encoded bundle payload. It is safe to write to a normal file.
public struct ConfigBundleEnvelope: Codable, Equatable, Sendable {
    public let manifest: ConfigBundleManifest
    public let secretPack: ConfigBundleSecretPack?

    public init(manifest: ConfigBundleManifest, secretPack: ConfigBundleSecretPack? = nil) {
        self.manifest = manifest
        self.secretPack = secretPack
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(self)
        } catch {
            throw ConfigBundleError.archiveWriteFailed
        }
    }

    public static func from(data: Data) throws -> ConfigBundleEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ConfigBundleEnvelope.self, from: data)
        } catch {
            throw ConfigBundleError.archiveDecodeFailed
        }
    }
}

/// Path helpers shared by export and import. The import side also checks at
/// extraction time (defence in depth).
public enum ConfigBundlePath {
    public static func validate(_ path: String) throws {
        guard !path.isEmpty else { throw ConfigBundleError.invalidPath }
        guard !path.hasPrefix("/"), !path.hasPrefix("\\") else { throw ConfigBundleError.invalidPath }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let comps = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !comps.isEmpty else { throw ConfigBundleError.invalidPath }
        guard comps.count <= 8 else { throw ConfigBundleError.invalidPath }
        for component in comps {
            guard !component.contains("\u{0}"),
                  component != ".",
                  component != ".."
            else { throw ConfigBundleError.invalidPath }
        }
    }

    public static func normalize(_ path: String) throws -> String {
        try validate(path)
        return path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }
}

/// SHA256 helper based on Apple's CryptoKit.
public enum ConfigBundleChecksum {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func parse(_ size: Int, stored: String) throws {
        guard size >= 0 else { throw ConfigBundleError.validationFailed("negative size") }
        guard stored.count == 64, stored.allSatisfy(\.isHexDigit) else {
            throw ConfigBundleError.validationFailed("invalid digest")
        }
    }
}

/// Builder for the export side. Caller supplies its file payload; this class
/// never reaches outside the supplied dictionary.
public enum ConfigBundleBuilder {
    public static func build(
        files: [String: Data],
        scopes: [String],
        appVersion: String,
        buildNumber: String,
        secretEntries: [ConfigBundleSecretEntry]? = nil,
        passphrase: String? = nil,
    ) throws -> ConfigBundleEnvelope {
        var bundled: [ConfigBundleFile] = []

        for (path, data) in files {
            let normalized = try ConfigBundlePath.normalize(path)
            bundled.append(try ConfigBundleFile(path: normalized, data: data))
        }

        let secretPack: ConfigBundleSecretPack?
        let hasSecretPack: Bool
        if let secretEntries, let passphrase, !passphrase.isEmpty {
            secretPack = try ConfigBundleCrypto.encrypt(passphrase: passphrase, entries: secretEntries)
            hasSecretPack = true
        } else {
            secretPack = nil
            hasSecretPack = false
        }

        let manifest = ConfigBundleManifest(
            appVersion: appVersion,
            buildNumber: buildNumber,
            scopes: scopes,
            files: bundled,
            hasSecretPack: hasSecretPack,
        )
        try ConfigBundleManifest.validate(manifest)
        return ConfigBundleEnvelope(manifest: manifest, secretPack: secretPack)
    }
}

/// Import-side validation and safe extraction.
public enum ConfigBundleParser {
    public static func load(_ data: Data) throws -> ConfigBundleEnvelope {
        let bundle = try ConfigBundleEnvelope.from(data: data)
        try ConfigBundleManifest.validate(bundle.manifest)
        return bundle
    }

    public static func verify(_ bundle: ConfigBundleEnvelope) throws {
        for file in bundle.manifest.files {
            try ConfigBundlePath.validate(file.path)
            guard let payload = file.data else { throw ConfigBundleError.checksumMismatch }
            guard ConfigBundleChecksum.sha256(payload) == file.sha256 else {
                throw ConfigBundleError.checksumMismatch
            }
        }
        if bundle.secretPack != nil && !bundle.manifest.hasSecretPack {
            throw ConfigBundleError.validationFailed("secret metadata mismatch")
        }
    }

    public static func extract(
        bundle: ConfigBundleEnvelope,
        into destinationRoot: URL,
        overwrite: Bool = false,
    ) throws -> [URL] {
        try verify(bundle)
        let fm = FileManager.default
        let rootPath = destinationRoot.path
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: rootPath, isDirectory: &isDirectory) {
            let attributes = try fm.attributesOfItem(atPath: rootPath)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ConfigBundleError.pathEscape
            }
            guard isDirectory.boolValue else { throw ConfigBundleError.invalidPath }
        } else {
            try fm.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        }
        guard let resolvedRoot = CanonicalPath.resolve(rootPath) else { return [] }
        var results: [URL] = []
        for file in bundle.manifest.files {
            let normalized = try ConfigBundlePath.normalize(file.path)
            guard let data = file.data else { throw ConfigBundleError.checksumMismatch }
            let components = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !components.isEmpty else { throw ConfigBundleError.invalidPath }
            var currentURL = URL(fileURLWithPath: resolvedRoot, isDirectory: true)
            for index in 0 ..< components.count {
                if index < components.count - 1 {
                    let next = currentURL.appendingPathComponent(components[index], isDirectory: true)
                    if fm.fileExists(atPath: next.path) {
                        let attributes = try fm.attributesOfItem(atPath: next.path)
                        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                            throw ConfigBundleError.pathEscape
                        }
                        if attributes[.type] as? FileAttributeType != .typeDirectory {
                            throw ConfigBundleError.pathEscape
                        }
                    } else {
                        try fm.createDirectory(at: next, withIntermediateDirectories: true)
                    }
                    guard let resolved = CanonicalPath.resolve(next.path),
                          CanonicalPath.isCanonical(resolved, inside: resolvedRoot)
                    else { throw ConfigBundleError.pathEscape }
                    currentURL = URL(fileURLWithPath: resolved, isDirectory: true)
                } else {
                    let parentURL = currentURL
                    let url = parentURL.appendingPathComponent(components[index])
                    if !overwrite, fm.fileExists(atPath: url.path) {
                        throw ConfigBundleError.validationFailed("target already exists: \(normalized)")
                    }
                    guard let resolvedParent = CanonicalPath.resolve(parentURL.path),
                          CanonicalPath.isCanonical(url.path, inside: resolvedParent)
                    else { throw ConfigBundleError.pathEscape }
                    try data.write(to: url, options: .atomic)
                    results.append(url)
                }
            }
        }
        return results
    }

    public static func decryptSecrets(
        bundle: ConfigBundleEnvelope,
        passphrase: String,
    ) throws -> [ConfigBundleSecretEntry] {
        guard let pack = bundle.secretPack else { throw ConfigBundleError.missingFile("secret pack") }
        return try ConfigBundleCrypto.decrypt(passphrase: passphrase, pack: pack)
    }
}

/// AES-256-GCM using PBKDF2 key derivation and CryptoKit for the seal.
public enum ConfigBundleCrypto {
    public static let keyLength = 32
    public static let saltLength = 16

    public static func encrypt(
        passphrase: String,
        entries: [ConfigBundleSecretEntry],
    ) throws -> ConfigBundleSecretPack {
        let salt = Data((0 ..< saltLength).map { _ in UInt8.random(in: .min ... .max) })
        let key = try deriveKey(passphrase: passphrase, salt: salt, rounds: 100_000)
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(entries)
        } catch {
            throw ConfigBundleError.secretEncryptionFailed
        }
        let nonce = AES.GCM.Nonce()
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        } catch {
            throw ConfigBundleError.secretEncryptionFailed
        }
        return ConfigBundleSecretPack(
            salt: salt,
            nonce: Data(nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
        )
    }

    public static func decrypt(
        passphrase: String,
        pack: ConfigBundleSecretPack,
    ) throws -> [ConfigBundleSecretEntry] {
        let key = try deriveKey(passphrase: passphrase, salt: pack.salt, rounds: 100_000)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: pack.nonce)
        } catch {
            throw ConfigBundleError.secretDecryptionFailed
        }
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: pack.ciphertext, tag: pack.tag)
        } catch {
            throw ConfigBundleError.secretDecryptionFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw ConfigBundleError.invalidPassphrase
        }
        do {
            return try JSONDecoder().decode([ConfigBundleSecretEntry].self, from: plaintext)
        } catch {
            throw ConfigBundleError.secretDecryptionFailed
        }
    }

    public static func deriveKey(
        passphrase: String,
        salt: Data,
        rounds: Int,
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty else { throw ConfigBundleError.invalidPassphrase }
        var output = Data(repeating: 0, count: keyLength)
        let passwordBytes = Data(passphrase.utf8)
        let outputLength = output.count
        let result = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                output.withUnsafeMutableBytes { outputBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordBytes.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        outputLength,
                    )
                }
            }
        }
        guard result == 0 else { throw ConfigBundleError.secretEncryptionFailed }
        return SymmetricKey(data: output)
    }
}
