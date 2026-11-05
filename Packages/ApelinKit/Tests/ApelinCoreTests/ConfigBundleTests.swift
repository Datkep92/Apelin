import ApelinCore
import Foundation
import XCTest

final class ConfigBundleTests: XCTestCase {
    func testBuildAndLoadPreservesChecksums() throws {
        let bundleData = try ConfigBundleBuilder.build(
            files: ["memories.json": Data("{}".utf8), "skills/a/SKILL.md": Data("secret".utf8)],
            scopes: ["memory", "skills"],
            appVersion: "0.4.14",
            buildNumber: "145",
        ).data()
        let bundle = try ConfigBundleParser.load(bundleData)
        try ConfigBundleParser.verify(bundle)
        XCTAssertEqual(bundle.manifest.scopes, ["memory", "skills"])
        XCTAssertEqual(bundle.manifest.files.count, 2)
        XCTAssertEqual(bundle.manifest.files.first(where: { $0.path == "skills/a/SKILL.md" })?.size, 6)
        XCTAssertEqual(try ConfigBundleParser.load(bundleData).manifest.files.first(where: { $0.path == "memories.json" })?.data, Data("{}".utf8))
    }

    func testDetectsChecksumTampering() throws {
        let tamperedFile = ConfigBundleFile(
            path: "memories.json",
            size: 2,
            sha256: "b8c5a1496926aa9d42a3436744fb6d081a588b5dc92dbc59f4a165a1a16cc6fe",
            contentBase64: Data("x".utf8).base64EncodedString(),
        )
        XCTAssertThrowsError(
            try ConfigBundleParser.verify(
                ConfigBundleEnvelope(
                    manifest: ConfigBundleManifest(
                        appVersion: "0.4.14",
                        buildNumber: "145",
                        scopes: ["memory"],
                        files: [tamperedFile],
                        hasSecretPack: false,
                    ),
                    secretPack: nil,
                )
            )
        ) { error in
            XCTAssertEqual(error as? ConfigBundleError, .checksumMismatch)
        }
    }

    func testInvalidPathRejected() {
        XCTAssertThrowsError(try ConfigBundlePath.validate("skills/../x")) { error in
            XCTAssertEqual(error as? ConfigBundleError, .invalidPath)
        }
        XCTAssertThrowsError(try ConfigBundlePath.validate("/absolute")) { error in
            XCTAssertEqual(error as? ConfigBundleError, .invalidPath)
        }
        XCTAssertThrowsError(try ConfigBundlePath.validate("..")) { error in
            XCTAssertEqual(error as? ConfigBundleError, .invalidPath)
        }
        XCTAssertNoThrow(try ConfigBundlePath.validate("settings/git.json"))
    }

    func testExtractsFilesInsideDestinationOnly() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try ConfigBundleBuilder.build(
            files: [
                "memory.json": Data("{title:x}".utf8),
                "settings/git.json": Data("{\"author\":\"me\"}".utf8)
            ],
            scopes: ["memory", "settings"],
            appVersion: "0.4.14",
            buildNumber: "145",
        )
        let files = try ConfigBundleParser.extract(bundle: bundle, into: root, overwrite: false)
        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings/git.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("memory.json").path))
    }

    func testFailsExtractionIfTargetExistsWithoutOverwrite() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("existing".utf8).write(to: root.appendingPathComponent("memory.json"))
        let bundle = try ConfigBundleBuilder.build(
            files: ["memory.json": Data("new".utf8)],
            scopes: ["memory"],
            appVersion: "0.4.14",
            buildNumber: "145",
        )
        XCTAssertThrowsError(
            try ConfigBundleParser.extract(bundle: bundle, into: root, overwrite: false)
        ) { error in
            if case ConfigBundleError.validationFailed(_) = error {} else { XCTFail("expected validationFailed") }
        }
    }

    func testSecretRoundTripSuccessAndWrongPassphraseFailure() throws {
        let entries = [
            ConfigBundleSecretEntry(providerID: "openai", token: "sk-test-123"),
            ConfigBundleSecretEntry(providerID: "anthropic", token: "ak-test-456"),
        ]
        let bundle = try ConfigBundleBuilder.build(
            files: ["memory.json": Data("{}".utf8)],
            scopes: ["memory"],
            appVersion: "0.4.14",
            buildNumber: "145",
            secretEntries: entries,
            passphrase: "hunter2!"
        )
        XCTAssertTrue(bundle.manifest.hasSecretPack)
        let loaded = try ConfigBundleParser.load(try bundle.data())
        let restored = try ConfigBundleParser.decryptSecrets(bundle: loaded, passphrase: "hunter2!")
        XCTAssertEqual(restored, entries)

        XCTAssertThrowsError(
            try ConfigBundleParser.decryptSecrets(bundle: loaded, passphrase: "wrong")
        ) { (error: Error) in
            XCTAssertEqual(error as? ConfigBundleError, .invalidPassphrase)
        }
    }

// MARK: - Hardened security cases

    func testRejectsDuplicatePaths() throws {
        let manifest = ConfigBundleManifest(
            appVersion: "0.4.14",
            buildNumber: "145",
            scopes: ["memory"],
            files: [
                ConfigBundleFile(path: "memory.json", size: 1, sha256: ConfigBundleChecksum.sha256(Data("a".utf8)), contentBase64: Data("a".utf8).base64EncodedString()),
                ConfigBundleFile(path: "memory.json", size: 1, sha256: ConfigBundleChecksum.sha256(Data("a".utf8)), contentBase64: Data("a".utf8).base64EncodedString()),
            ],
            hasSecretPack: false,
        )
        XCTAssertThrowsError(try ConfigBundleManifest.validate(manifest)) { error in
            XCTAssertEqual(error as? ConfigBundleError, .invalidPath)
        }
    }

    func testRejectsBundleParseWithoutChecksumPayload() throws {
        let invalidManifest = ConfigBundleManifest(
            appVersion: "0.4.14",
            buildNumber: "145",
            scopes: ["memory"],
            files: [
                ConfigBundleFile(path: "memory.json", size: 0, sha256: ConfigBundleChecksum.sha256(Data()), contentBase64: ""),
            ],
            hasSecretPack: false,
        )
        let envelope = ConfigBundleEnvelope(manifest: invalidManifest, secretPack: nil)
        XCTAssertThrowsError(try ConfigBundleParser.verify(envelope))
    }

    func testExtractRefusesSymlinkParentEscape() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("settings"), withDestinationURL: outside)

        let bundle = try ConfigBundleBuilder.build(
            files: ["settings/git.json": Data("{\"x\":1}".utf8)],
            scopes: ["settings"],
            appVersion: "0.4.14",
            buildNumber: "145",
        )
        XCTAssertThrowsError(try ConfigBundleParser.extract(bundle: bundle, into: destination, overwrite: false))
    }
}
