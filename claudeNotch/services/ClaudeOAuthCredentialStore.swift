//
//  ClaudeOAuthCredentialStore.swift
//  claudeNotch
//
//  Reads Claude Code CLI OAuth credentials from keychain or ~/.claude/.credentials.json
//

import Foundation

// MARK: - Credential Models

struct ClaudeOAuthCredentials {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scopes: [String]?

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

    /// Claude Code's public OAuth client ID (used for token refresh)
    private let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Refresh endpoint
    private let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// File path for credentials
    private var credentialsFilePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent(".credentials.json")
    }

    /// Cached credentials
    private var cachedCredentials: ClaudeOAuthCredentials?
    private var cacheTimestamp: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    /// Where the current credentials were loaded from. Determines where refreshed
    /// tokens get persisted so we don't invalidate Claude Code's rotated refresh token.
    private enum CredentialSource {
        case env
        case keychain(account: String)
        case file
    }
    private var credentialSource: CredentialSource?

    private init() {}

    // MARK: - Public API

    /// Load credentials, trying keychain first then file
    func loadCredentials() -> ClaudeOAuthCredentials? {
        // Check cache
        if let cached = cachedCredentials,
           let timestamp = cacheTimestamp,
           Date().timeIntervalSince(timestamp) < cacheTTL,
           !cached.isExpired {
            return cached
        }

        // Try env var first
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"] {
            let creds = ClaudeOAuthCredentials(
                accessToken: token,
                refreshToken: nil,
                expiresAt: nil,
                scopes: nil
            )
            credentialSource = .env
            cache(creds)
            return creds
        }

        // Try keychain (via security CLI to avoid permission dialogs)
        if let creds = loadFromKeychain() {
            credentialSource = .keychain(account: keychainAccount() ?? "")
            cache(creds)
            return creds
        }

        // Try credentials file
        if let creds = loadFromFile() {
            credentialSource = .file
            cache(creds)
            return creds
        }

        return nil
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

    /// Refresh an expired token
    func refreshToken(using refreshToken: String) async -> ClaudeOAuthCredentials? {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(oauthClientID)"
        request.httpBody = body.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[ClaudeOAuthCredentialStore] Token refresh failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let accessToken = json?["access_token"] as? String else {
                print("[ClaudeOAuthCredentialStore] No access_token in refresh response")
                return nil
            }

            let newRefreshToken = json?["refresh_token"] as? String ?? refreshToken
            let expiresIn = json?["expires_in"] as? TimeInterval
            let expiresAt = expiresIn.map { Date().addingTimeInterval($0) }

            let creds = ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: newRefreshToken,
                expiresAt: expiresAt,
                scopes: nil
            )
            // Persist rotated tokens back to the shared store BEFORE caching.
            // Anthropic rotates the refresh token on every refresh; if we don't write
            // it back, Claude Code's stored refresh token goes stale and forces /login.
            persistRefreshedCredentials(creds)
            cache(creds)
            return creds
        } catch {
            print("[ClaudeOAuthCredentialStore] Token refresh error: \(error)")
            return nil
        }
    }

    /// Trigger Claude CLI to refresh its token by running `claude /status`
    func triggerCLIRefresh() {
        // Use a login shell to pick up the user's full PATH,
        // since GUI apps don't inherit terminal PATH.
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: userShell)
        process.arguments = ["-l", "-c", "claude /status"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            invalidateCache()
        } catch {
            print("[ClaudeOAuthCredentialStore] CLI refresh failed: \(error)")
        }
    }

    // MARK: - Keychain Reading

    private func loadFromKeychain() -> ClaudeOAuthCredentials? {
        guard let jsonString = readKeychainRaw() else { return nil }
        return parseCredentialsJSON(jsonString)
    }

    /// Read the raw JSON blob from the keychain entry, or nil if absent.
    /// Uses /usr/bin/security CLI to avoid macOS permission dialogs.
    private func readKeychainRaw() -> String? {
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
                print("[ClaudeOAuthCredentialStore] Keychain entry not found (status \(process.terminationStatus))")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                return nil
            }
            return jsonString
        } catch {
            print("[ClaudeOAuthCredentialStore] Keychain read error: \(error)")
            return nil
        }
    }

    /// Read the account name ("acct" attribute) of the keychain entry so we can
    /// preserve it when updating the entry.
    private func keychainAccount() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Attribute line looks like: "acct"<blob>="someaccount"
            guard let range = output.range(of: "\"acct\"<blob>=\"") else { return nil }
            let rest = output[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            let account = String(rest[..<end])
            return account.isEmpty ? nil : account
        } catch {
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
            return parseCredentialsJSON(jsonString)
        } catch {
            print("[ClaudeOAuthCredentialStore] File read error: \(error)")
            return nil
        }
    }

    // MARK: - JSON Parsing

    private func parseCredentialsJSON(_ jsonString: String) -> ClaudeOAuthCredentials? {
        guard let data = jsonString.data(using: .utf8) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            guard let oauthDict = json?["claudeAiOauth"] as? [String: Any],
                  let accessToken = oauthDict["accessToken"] as? String else {
                print("[ClaudeOAuthCredentialStore] Missing claudeAiOauth.accessToken in credentials")
                return nil
            }

            let refreshToken = oauthDict["refreshToken"] as? String
            let expiresAtMs = oauthDict["expiresAt"] as? Double
            let expiresAt = expiresAtMs.map { Date(timeIntervalSince1970: $0 / 1000.0) }
            let scopes = oauthDict["scopes"] as? [String]

            return ClaudeOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                scopes: scopes
            )
        } catch {
            print("[ClaudeOAuthCredentialStore] JSON parse error: \(error)")
            return nil
        }
    }

    // MARK: - Persistence

    /// Write refreshed tokens back to whichever source they were loaded from.
    private func persistRefreshedCredentials(_ creds: ClaudeOAuthCredentials) {
        switch credentialSource {
        case .keychain(let account):
            persistToKeychain(creds, account: account)
        case .file:
            persistToFile(creds)
        case .env, .none:
            // Env-var token has no refresh token — nothing to persist.
            // .none shouldn't happen (refresh implies a prior load), but be safe.
            break
        }
    }

    /// Merge refreshed tokens into an existing credential JSON document, preserving
    /// any keys we don't manage (other top-level keys, scopes, etc.).
    private func mergedCredentialJSON(existing: String?, creds: ClaudeOAuthCredentials) -> String? {
        var root: [String: Any] = [:]
        if let existing,
           let data = existing.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }

        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = creds.accessToken
        if let refreshToken = creds.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = creds.expiresAt {
            // File/keychain store milliseconds since epoch.
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        if let scopes = creds.scopes {
            oauth["scopes"] = scopes
        }
        root["claudeAiOauth"] = oauth

        guard let out = try? JSONSerialization.data(withJSONObject: root),
              let string = String(data: out, encoding: .utf8) else {
            return nil
        }
        return string
    }

    private func persistToKeychain(_ creds: ClaudeOAuthCredentials, account: String) {
        guard !account.isEmpty else {
            print("[ClaudeOAuthCredentialStore] Skipping keychain persist: no account name")
            return
        }
        guard let json = mergedCredentialJSON(existing: readKeychainRaw(), creds: creds) else {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        // -U updates the entry if it already exists.
        process.arguments = ["add-generic-password", "-U", "-s", keychainService, "-a", account, "-w", json]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                print("[ClaudeOAuthCredentialStore] Keychain persist failed (status \(process.terminationStatus))")
            }
        } catch {
            print("[ClaudeOAuthCredentialStore] Keychain persist error: \(error)")
        }
    }

    private func persistToFile(_ creds: ClaudeOAuthCredentials) {
        // Only rewrite if the file already existed when loaded.
        guard FileManager.default.fileExists(atPath: credentialsFilePath.path) else {
            return
        }

        let existing = try? String(contentsOf: credentialsFilePath, encoding: .utf8)
        guard let json = mergedCredentialJSON(existing: existing, creds: creds),
              let data = json.data(using: .utf8) else {
            return
        }

        // Write atomically (temp + rename) with 0600 permissions.
        let tempURL = credentialsFilePath.deletingLastPathComponent()
            .appendingPathComponent(".credentials.json.tmp.\(UUID().uuidString)")
        do {
            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            _ = try FileManager.default.replaceItemAt(credentialsFilePath, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            print("[ClaudeOAuthCredentialStore] File persist error: \(error)")
        }
    }

    // MARK: - Cache

    private func cache(_ creds: ClaudeOAuthCredentials) {
        cachedCredentials = creds
        cacheTimestamp = Date()
    }
}
