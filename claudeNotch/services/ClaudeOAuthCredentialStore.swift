//
//  ClaudeOAuthCredentialStore.swift
//  claudeNotch
//
//  Reads Claude Code CLI OAuth credentials from env, keychain or ~/.claude/.credentials.json
//

import Foundation

// MARK: - Credential Models

struct ClaudeOAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]?
    /// Where the token came from ("env", "keychain", "file"), for diagnostics.
    var source: String = "unknown"

    /// Only true when a real expiry is known and has passed. A missing or zero
    /// expiresAt means "unknown" and the token is still worth trying.
    var isExpired: Bool {
        guard let expiresAt = expiresAt else { return false }
        return expiresAt < Date()
    }
}

// MARK: - Credential Store

class ClaudeOAuthCredentialStore {
    static let shared = ClaudeOAuthCredentialStore()

    /// Claude Code's keychain service name
    private let keychainService = "Claude Code-credentials"

    /// File path for credentials
    private var credentialsFilePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    /// Cached credentials (the last ones the API accepted, or the first candidate)
    private var cachedCredentials: ClaudeOAuthCredentials?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    private init() {}

    // MARK: - Public API

    /// The preferred usable credentials (cached for a few minutes).
    func loadCredentials() -> ClaudeOAuthCredentials? {
        if let cached = cachedCredentials,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheTTL,
           !cached.isExpired {
            return cached
        }
        guard let first = loadAllCredentials().first else { return nil }
        cache(first)
        return first
    }

    /// Every usable credential, in order of preference: env var, keychain, file.
    /// Tokens with a known, passed expiry are skipped; duplicates are dropped.
    ///
    /// These tokens belong to Claude Code. This app never refreshes them: a
    /// refresh rotates the refresh token and would sign Claude Code out. Claude
    /// Code keeps the keychain entry current on its own.
    func loadAllCredentials() -> [ClaudeOAuthCredentials] {
        var candidates: [ClaudeOAuthCredentials] = []

        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"], !token.isEmpty {
            candidates.append(ClaudeOAuthCredentials(
                accessToken: token, refreshToken: nil, expiresAt: nil, scopes: nil, source: "env"))
        }
        if let creds = loadFromKeychain() { candidates.append(creds) }
        if let creds = loadFromFile() { candidates.append(creds) }

        var seen = Set<String>()
        var usable: [ClaudeOAuthCredentials] = []
        for c in candidates {
            if c.isExpired {
                DebugLog.log("[ClaudeOAuthCredentialStore] \(c.source) token expired at \(c.expiresAt!) - skipping")
                continue
            }
            if seen.insert(c.accessToken).inserted { usable.append(c) }
        }
        DebugLog.log("[ClaudeOAuthCredentialStore] usable credential sources: \(usable.map { $0.source })")
        return usable
    }

    /// Remember the credentials the API accepted.
    func markWorking(_ creds: ClaudeOAuthCredentials) {
        cache(creds)
    }

    /// Check if any credentials are available
    var hasCredentials: Bool {
        return loadCredentials() != nil
    }

    /// Clear cached credentials (e.g. after login)
    func invalidateCache() {
        cachedCredentials = nil
        cacheTimestamp = nil
    }

    // MARK: - Keychain Reading

    private func loadFromKeychain() -> ClaudeOAuthCredentials? {
        // Use /usr/bin/security CLI to avoid macOS permission dialogs
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                // 36 = keychain locked (e.g. launched from an SSH session), 44 = no such item
                DebugLog.log("[ClaudeOAuthCredentialStore] Keychain read failed (security exit \(process.terminationStatus))")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                return nil
            }

            return parseCredentialsJSON(jsonString, source: "keychain")
        } catch {
            DebugLog.log("[ClaudeOAuthCredentialStore] Keychain read error: \(error)")
            return nil
        }
    }

    // MARK: - File Reading

    private func loadFromFile() -> ClaudeOAuthCredentials? {
        guard FileManager.default.fileExists(atPath: credentialsFilePath.path) else {
            print("[ClaudeOAuthCredentialStore] Credentials file not found at \(credentialsFilePath.path)")
            return nil
        }

        do {
            let jsonString = try String(contentsOf: credentialsFilePath, encoding: .utf8)
            return parseCredentialsJSON(jsonString, source: "file")
        } catch {
            DebugLog.log("[ClaudeOAuthCredentialStore] File read error: \(error)")
            return nil
        }
    }

    // MARK: - JSON Parsing

    private func parseCredentialsJSON(_ jsonString: String, source: String) -> ClaudeOAuthCredentials? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let oauthDict = json?["claudeAiOauth"] as? [String: Any],
                  let accessToken = oauthDict["accessToken"] as? String else {
                DebugLog.log("[ClaudeOAuthCredentialStore] Missing claudeAiOauth.accessToken in credentials")
                return nil
            }

            let refreshToken = oauthDict["refreshToken"] as? String
            // expiresAt is epoch milliseconds; 0 or missing means unknown.
            let expiresAtMs = (oauthDict["expiresAt"] as? NSNumber)?.doubleValue ?? 0
            let expiresAt = expiresAtMs > 0 ? Date(timeIntervalSince1970: expiresAtMs / 1000.0) : nil
            let scopes = oauthDict["scopes"] as? [String]

            return ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                scopes: scopes,
                source: source
            )
        } catch {
            print("[ClaudeOAuthCredentialStore] JSON parse error: \(error)")
            return nil
        }
    }

    // MARK: - Cache

    private func cache(_ creds: ClaudeOAuthCredentials) {
        cachedCredentials = creds
        cacheTimestamp = Date()
    }
}
