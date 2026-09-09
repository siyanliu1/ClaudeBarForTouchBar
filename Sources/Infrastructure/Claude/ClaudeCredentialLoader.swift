import Foundation
import Domain

/// OAuth credentials loaded from Claude credential storage.
public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Double?  // Milliseconds since epoch
    /// When the refresh token itself dies. Past this, no refresh can succeed and
    /// the user has to log in again — which is a different thing to tell them
    /// than "your token needs refreshing".
    public var refreshTokenExpiresAt: Double?  // Milliseconds since epoch
    public var subscriptionType: String?

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Double? = nil,
        refreshTokenExpiresAt: Double? = nil,
        subscriptionType: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.subscriptionType = subscriptionType
    }
}

extension ClaudeCredentialLoader {
    /// A loader that finds nothing, anywhere. The parsing seam defaults to this
    /// so a test never reads the credentials of whatever machine runs it.
    public static let findsNothing = ClaudeCredentialLoader(
        homeDirectory: "/var/empty",
        useKeychain: false,
        environment: [:]
    )
}

/// Source of loaded credentials.
public enum CredentialSource: Sendable, Equatable {
    case environment
    case file
    case keychain
}

/// Result of loading credentials.
/// Note: fullData contains the raw JSON for persisting changes, marked @unchecked Sendable
/// because [String: Any] can't conform to Sendable but we only use it within a single context.
public struct ClaudeCredentialResult: @unchecked Sendable {
    public var oauth: ClaudeOAuthCredentials
    public let source: CredentialSource
    public var fullData: [String: Any]

    public init(oauth: ClaudeOAuthCredentials, source: CredentialSource, fullData: [String: Any]) {
        self.oauth = oauth
        self.source = source
        self.fullData = fullData
    }
}

/// Loads Claude OAuth credentials from file, Keychain, or environment.
///
/// Credential resolution order:
/// 1. File: `~/.claude/.credentials.json` (full-scope from `claude login`)
/// 2. Keychain: Service "Claude Code-credentials" (if enabled)
/// 3. Environment: `CLAUDE_CODE_OAUTH_TOKEN` env var (inference-only from `claude setup-token`)
public struct ClaudeCredentialLoader: Sendable {
    private let homeDirectory: String
    private let keychainService: String
    private let useKeychain: Bool
    private let environment: [String: String]

    /// Refresh buffer: 5 minutes before expiration
    private static let refreshBufferMs: Double = 5 * 60 * 1000

    static func keychainSaveArguments(
        service: String,
        account: String,
        password: String
    ) -> [String] {
        [
            "add-generic-password",
            "-U",
            "-s", service,
            "-a", account,
            "-w", password
        ]
    }

    /// Serializes credentials for the Keychain.
    ///
    /// Deliberately compact: `security find-generic-password -w` on macOS 26
    /// returns any password containing a byte outside printable ASCII as a hex
    /// string rather than raw text, and pretty-printing's newlines are enough
    /// to trigger it — leaving a password we can write but not read back (#255).
    static func keychainPayload(from data: [String: Any]) -> String? {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) else {
            return nil
        }
        return String(data: jsonData, encoding: .utf8)
    }

    /// Decodes a password read back from `security find-generic-password -w`,
    /// undoing the macOS 26 hex encoding when present.
    ///
    /// A payload written by an older ClaudeBar build comes back hex-encoded;
    /// this keeps those users working instead of stranding them until their
    /// next `claude` login. Valid JSON always starts with `{`, which is not a
    /// hex digit, so an all-hex payload is unambiguously the encoded form.
    static func decodeKeychainPayload(_ raw: String) -> Data? {
        if let decoded = hexDecoded(raw) {
            return decoded
        }
        return raw.data(using: .utf8)
    }

    private static func hexDecoded(_ string: String) -> Data? {
        guard !string.isEmpty, string.count % 2 == 0 else { return nil }

        var bytes = [UInt8]()
        bytes.reserveCapacity(string.count / 2)

        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    public init(
        homeDirectory: String = NSHomeDirectory(),
        keychainService: String = "Claude Code-credentials",
        useKeychain: Bool = true,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.keychainService = keychainService
        self.useKeychain = useKeychain
        self.environment = environment
    }

    /// The path to the credentials file.
    public var credentialsFilePath: String {
        (homeDirectory as NSString).appendingPathComponent(".claude/.credentials.json")
    }

    /// Loads credentials from file, Keychain, or environment.
    /// Returns nil if no valid credentials are found.
    ///
    /// Priority: file/keychain credentials (full-scope from `claude login`) are preferred
    /// over the `CLAUDE_CODE_OAUTH_TOKEN` env var (inference-only from `claude setup-token`).
    /// This ensures quota monitoring uses full-scope credentials when available,
    /// while still falling back to the env var token if nothing else exists.
    public func loadCredentials() -> ClaudeCredentialResult? {
        // Only a session there is something to authenticate with. Callers use
        // this to decide "is Claude configured at all", so a blanked session
        // must keep reading as nil here.
        if let stored = loadStoredSession(), !stored.oauth.accessToken.isEmpty {
            return stored
        }

        // Fallback to environment variable (setup-token, inference-only scope)
        if let envResult = loadFromEnvironment() {
            return envResult
        }

        return nil
    }

    /// The stored session exactly as it sits on disk — including the shape a
    /// dead one leaves behind, where the Keychain item survives with both
    /// tokens blanked and only the timestamps and plan left.
    ///
    /// ``loadCredentials()`` deliberately hides that, because there is nothing
    /// there to authenticate with. This answers the different question of what
    /// the machine *says* about the session, which is how "you are logged out"
    /// can be told apart from "you never set Claude up" — two states that need
    /// very different things said to the user.
    public func loadStoredSession() -> ClaudeCredentialResult? {
        let fileResult = loadFromFile()
        if let fileResult, !fileResult.oauth.accessToken.isEmpty {
            return fileResult
        }

        let keychainResult = useKeychain ? loadFromKeychain() : nil
        if let keychainResult, !keychainResult.oauth.accessToken.isEmpty {
            return keychainResult
        }

        // Neither is usable; report whichever actually exists.
        return fileResult ?? keychainResult
    }

    /// Checks if the token needs to be refreshed (expired or within 5 minutes of expiry).
    public func needsRefresh(_ oauth: ClaudeOAuthCredentials) -> Bool {
        guard let expiresAt = oauth.expiresAt else {
            return true
        }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs + Self.refreshBufferMs >= expiresAt
    }

    /// Whether the session is past the point a refresh could rescue it, so the
    /// only way back is `claude login`.
    ///
    /// Deliberately answers false whenever it cannot *prove* otherwise: a token
    /// with no recorded expiry (what `claude setup-token` writes) is unknown,
    /// not dead, and reporting it as expired would send users to log in over a
    /// session that works. ``needsRefresh(_:)`` is the opposite — it errs toward
    /// refreshing — because being wrong there costs a round trip, not a lie.
    public func isBeyondRefresh(_ oauth: ClaudeOAuthCredentials) -> Bool {
        let nowMs = Date().timeIntervalSince1970 * 1000

        // Both tokens blanked is the state `claude` leaves behind when a session
        // dies. No timestamp needed to know there is nothing left to refresh.
        if oauth.accessToken.isEmpty, oauth.refreshToken?.isEmpty ?? true {
            return true
        }

        // The access token has to be provably dead before anything else matters.
        guard let expiresAt = oauth.expiresAt, nowMs >= expiresAt else { return false }

        // Nothing to refresh with.
        guard let refreshToken = oauth.refreshToken, !refreshToken.isEmpty else { return true }

        // A refresh token with no stated expiry is assumed good.
        guard let refreshExpiresAt = oauth.refreshTokenExpiresAt else { return false }
        return nowMs >= refreshExpiresAt
    }

    /// Saves updated credentials back to the original source.
    public func saveCredentials(_ result: ClaudeCredentialResult) {
        // Environment credentials are read-only (set via env var, not persisted by us)
        if result.source == .environment {
            return
        }

        var updatedData = result.fullData

        // Merge into the existing OAuth section so fields we do not model
        // (e.g. `scopes`) survive the write-back — the file is shared with
        // Claude Code, which reads them.
        var oauthDict = (result.fullData["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauthDict["accessToken"] = result.oauth.accessToken
        if let refreshToken = result.oauth.refreshToken {
            oauthDict["refreshToken"] = refreshToken
        }
        if let expiresAt = result.oauth.expiresAt {
            oauthDict["expiresAt"] = expiresAt
        }
        if let subscriptionType = result.oauth.subscriptionType {
            oauthDict["subscriptionType"] = subscriptionType
        }
        updatedData["claudeAiOauth"] = oauthDict

        switch result.source {
        case .environment:
            return  // Already handled above, but satisfy exhaustive switch
        case .file:
            saveToFile(updatedData)
        case .keychain:
            saveToKeychain(updatedData)
        }
    }

    // MARK: - Private: Environment Operations

    private func loadFromEnvironment() -> ClaudeCredentialResult? {
        guard let rawToken = environment["CLAUDE_CODE_OAUTH_TOKEN"] else {
            return nil
        }

        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return nil
        }

        let oauth = ClaudeOAuthCredentials(
            accessToken: token,
            refreshToken: nil,
            expiresAt: nil
        )

        return ClaudeCredentialResult(oauth: oauth, source: .environment, fullData: [:])
    }

    // MARK: - Private: File Operations

    private func loadFromFile() -> ClaudeCredentialResult? {
        let path = credentialsFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauthDict = json["claudeAiOauth"] as? [String: Any],
                  let rawAccessToken = oauthDict["accessToken"] as? String else {
                return nil
            }

            // A blank token is kept rather than dropped: it is what a logged-out
            // session looks like on disk, and `loadCredentials` filters it out
            // for callers who need something to authenticate with.
            let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)

            let oauth = ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: oauthDict["refreshToken"] as? String,
                expiresAt: oauthDict["expiresAt"] as? Double,
                refreshTokenExpiresAt: oauthDict["refreshTokenExpiresAt"] as? Double,
                subscriptionType: oauthDict["subscriptionType"] as? String
            )

            return ClaudeCredentialResult(oauth: oauth, source: .file, fullData: json)
        } catch {
            AppLog.credentials.error("Failed to load Claude credentials from file: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveToFile(_ data: [String: Any]) {
        let path = credentialsFilePath
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
            try jsonData.write(to: URL(fileURLWithPath: path), options: .atomic)
            AppLog.credentials.info("Saved updated Claude credentials to file")
        } catch {
            AppLog.credentials.error("Failed to save Claude credentials to file: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: Keychain Operations

    private func loadFromKeychain() -> ClaudeCredentialResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]

        let pipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            // Drain before waiting: `waitUntilExit()` first would deadlock if the
            // child ever filled the pipe buffer, since nothing is reading it.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // On macOS the Keychain is the only place `claude login` leaves
            // credentials — there is no `~/.claude/.credentials.json` to fall
            // back to. A silent nil here surfaces as "Authentication required.
            // Please log in." to someone who is already logged in, with nothing
            // in the log to say the read was denied rather than empty (#271).
            guard process.terminationStatus == 0 else {
                let stderr = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                AppLog.credentials.error(
                    "Keychain read of '\(keychainService)' failed: security exited \(process.terminationStatus)"
                    + (stderr.isEmpty ? "" : " — \(stderr)")
                )
                return nil
            }

            guard let jsonString = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                AppLog.credentials.error("Keychain item '\(keychainService)' held an empty password")
                return nil
            }

            guard let jsonData = Self.decodeKeychainPayload(jsonString),
                  let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let oauthDict = json["claudeAiOauth"] as? [String: Any],
                  let rawAccessToken = oauthDict["accessToken"] as? String else {
                // Shape only — never the payload, which is the token itself.
                AppLog.credentials.error(
                    "Keychain item '\(keychainService)' did not hold a readable claudeAiOauth access token"
                )
                return nil
            }

            // A blank token is kept rather than dropped: it is what a logged-out
            // session looks like on disk, and `loadCredentials` filters it out
            // for callers who need something to authenticate with.
            let accessToken = rawAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)

            let oauth = ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: oauthDict["refreshToken"] as? String,
                expiresAt: oauthDict["expiresAt"] as? Double,
                refreshTokenExpiresAt: oauthDict["refreshTokenExpiresAt"] as? Double,
                subscriptionType: oauthDict["subscriptionType"] as? String
            )

            return ClaudeCredentialResult(oauth: oauth, source: .keychain, fullData: json)
        } catch {
            AppLog.credentials.error("Failed to load Claude credentials from Keychain via security CLI: \(error.localizedDescription)")
            return nil
        }
    }

    private func saveToKeychain(_ data: [String: Any]) {
        guard let jsonString = Self.keychainPayload(from: data) else {
            AppLog.credentials.error("Failed to serialize Claude credentials for Keychain")
            return
        }

        let addProcess = Process()
        addProcess.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        addProcess.arguments = Self.keychainSaveArguments(
            service: keychainService,
            account: NSUserName(),
            password: jsonString
        )
        addProcess.standardOutput = Pipe()
        addProcess.standardError = Pipe()

        do {
            try addProcess.run()
            addProcess.waitUntilExit()

            if addProcess.terminationStatus == 0 {
                AppLog.credentials.info("Saved Claude credentials to Keychain")
            } else {
                AppLog.credentials.error("Failed to save Claude credentials to Keychain (exit code: \(addProcess.terminationStatus))")
            }
        } catch {
            AppLog.credentials.error("Failed to save Claude credentials to Keychain: \(error.localizedDescription)")
        }
    }
}
