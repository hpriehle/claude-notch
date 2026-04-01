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
            cache(creds)
            return creds
        }

        // Try keychain (via security CLI to avoid permission dialogs)
        if let creds = loadFromKeychain() {
            cache(creds)
            return creds
        }

        // Try credentials file
        if let creds = loadFromFile() {
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
                print("[ClaudeOAuthCredentialStore] Keychain entry not found (status \(process.terminationStatus))")
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                return nil
            }

            return parseCredentialsJSON(jsonString)
        } catch {
            print("[ClaudeOAuthCredentialStore] Keychain read error: \(error)")
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

    // MARK: - Cache

    private func cache(_ creds: ClaudeOAuthCredentials) {
        cachedCredentials = creds
        cacheTimestamp = Date()
    }
}
