import XCTest
@testable import Claudemeter

final class KeychainCredentialStoreTests: XCTestCase {
    // MARK: - Output parsing

    func testAccountParsesQuotedBlob() {
        let output = """
        keychain: "/Users/x/Library/Keychains/login.keychain-db"
        class: "genp"
        attributes:
            0x00000007 <blob>="Claude Code-credentials"
            "acct"<blob>="probe user"
            "svce"<blob>="Claude Code-credentials"
        """
        XCTAssertEqual(KeychainCredentialStore.account(fromAttributes: Data(output.utf8)), "probe user")
    }

    func testAccountParsesHexBlob() {
        // security prints non-ASCII blobs as hex followed by a display string.
        let output = "    \"acct\"<blob>=0xE5B1B1E5B48E  \"\\345\\261\\261\\345\\264\\216\"\n"
        XCTAssertEqual(KeychainCredentialStore.account(fromAttributes: Data(output.utf8)), "山崎")
    }

    func testAccountIsNilWhenNullOrMissing() {
        XCTAssertNil(KeychainCredentialStore.account(fromAttributes: Data("    \"acct\"<blob>=<NULL>\n".utf8)))
        XCTAssertNil(KeychainCredentialStore.account(fromAttributes: Data("class: \"genp\"\n".utf8)))
    }

    func testSecretStripsExactlyOneTrailingNewline() {
        XCTAssertEqual(KeychainCredentialStore.secret(fromOutput: Data("{\"a\":1}\n".utf8)), Data("{\"a\":1}".utf8))
        XCTAssertEqual(KeychainCredentialStore.secret(fromOutput: Data("{\"a\":1}".utf8)), Data("{\"a\":1}".utf8))
        XCTAssertEqual(KeychainCredentialStore.secret(fromOutput: Data("x\n\n".utf8)), Data("x\n".utf8))
    }

    func testSecretDecodesHexFormUsedForNonPrintableData() {
        // security prints `{"k":"v 日本語"}` as a bare hex string.
        let hex = "7B226B223A227620E697A5E69CACE8AA9E227D\n"
        XCTAssertEqual(KeychainCredentialStore.secret(fromOutput: Data(hex.utf8)), Data(#"{"k":"v 日本語"}"#.utf8))
        XCTAssertEqual(KeychainCredentialStore.secret(fromOutput: Data()), Data())
    }

    func testErrorMessageDropsToolPrefixAndFallsBackToStatus() {
        XCTAssertEqual(
            KeychainCredentialStore.errorMessage(
                stderr: "security: SecKeychainItemCopyContent: User interaction is not allowed.\n", status: 36),
            "SecKeychainItemCopyContent: User interaction is not allowed.")
        XCTAssertEqual(KeychainCredentialStore.errorMessage(stderr: "", status: 7), "security が終了コード 7 で失敗しました")
    }

    // MARK: - Round trip against a scratch keychain (runs the real /usr/bin/security)

    func testReadWriteRoundTripOnScratchKeychain() async throws {
        let keychain = try Self.makeScratchKeychain()
        defer { Self.remove(keychain) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: keychain))
        let store = KeychainCredentialStore(keychainPath: keychain)

        // Nothing stored yet.
        do {
            _ = try await store.readItem()
            XCTFail("expected notFound")
        } catch CredentialsError.notFound {
        }

        // Seed the item the way Claude Code does (via security add-generic-password).
        let original = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":1},"mcpOAuth":{"s":{"k":"v \" q 日本語"}}}"#
        try Self.security([
            "add-generic-password", "-a", "probe user", "-s", KeychainCredentialStore.service, "-w", original, keychain,
        ])

        let item = try await store.readItem()
        XCTAssertEqual(item.account, "probe user")
        XCTAssertEqual(String(decoding: item.data, as: UTF8.self), original)

        let merged = try CredentialsJSON.merge(
            into: item.data, accessToken: "new", refreshToken: "r2", expiresAt: Date(timeIntervalSince1970: 2))
        try await store.write(merged, to: item)

        let reread = try await store.readItem()
        XCTAssertEqual(reread.account, "probe user")
        XCTAssertEqual(reread.data, merged)
        let creds = try CredentialsJSON.parse(reread.data)
        XCTAssertEqual(creds.accessToken, "new")
        XCTAssertEqual(creds.refreshToken, "r2")
    }

    func testToolFailureSurfacesAsKeychainError() async throws {
        // Never point `keychainPath` at a missing file here: security would fall back to the login keychain.
        let store = KeychainCredentialStore(tool: "/usr/bin/false")
        do {
            _ = try await store.readItem()
            XCTFail("expected keychain error")
        } catch let error as CredentialsError {
            XCTAssertTrue(error.isKeychainAccessFailure, "\(error)")
            XCTAssertEqual(error.localizedDescription, "Keychain エラー: security が終了コード 1 で失敗しました")
        }
    }

    func testWriteWithoutAccountIsRefusedBeforeTouchingTheKeychain() async throws {
        let store = KeychainCredentialStore(tool: "/usr/bin/false")
        do {
            try await store.write(Data("{}".utf8), to: KeychainItem(data: Data(), account: nil))
            XCTFail("expected malformed error")
        } catch let error as CredentialsError {
            XCTAssertFalse(error.isKeychainAccessFailure, "\(error)")
        }
    }

    // MARK: - Helpers

    private static func makeScratchKeychain() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudemeter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("scratch.keychain-db").path
        try security(["create-keychain", "-p", "scratch", path])
        return path
    }

    private static func remove(_ keychain: String) {
        try? security(["delete-keychain", keychain])
        try? FileManager.default.removeItem(atPath: (keychain as NSString).deletingLastPathComponent)
    }

    private static func security(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: KeychainCredentialStore.defaultTool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "security", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: err, as: UTF8.self)])
        }
    }
}
