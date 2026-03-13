//
//  ClaudeOAuthUsageFetcher.swift
//  claudeNotch
//
//  Fetches Claude usage data from the Anthropic OAuth API endpoint.
//  Piggybacks on Claude Code CLI's OAuth tokens.
//

import Foundation

// MARK: - OAuth Usage Response Models

struct OAuthUsageResponse: Codable {
    let fiveHour: OAuthRateWindow?
    let sevenDay: OAuthRateWindow?
    let sevenDayOauthApps: OAuthRateWindow?
    let sevenDayOpus: OAuthRateWindow?
    let sevenDaySonnet: OAuthRateWindow?
    let iguanaNecktie: OAuthRateWindow?
    let extraUsage: OAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
    }
}

struct OAuthRateWindow: Codable {
    let utilization: Double  // 0-100 percentage
    let resetsAt: String     // ISO 8601

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        // API format: "2026-03-13T07:00:01.068410+00:00"
        // Strategy: strip fractional seconds (unneeded for reset countdown),
        // then parse with ISO8601DateFormatter which reliably handles +00:00.

        // 1. Strip fractional seconds: ".068410" → ""
        let cleaned = resetsAt.replacingOccurrences(
            of: "\\.\\d+",
            with: "",
            options: .regularExpression
        )

        // 2. Parse cleaned string with ISO8601DateFormatter
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: cleaned) {
            NSLog("[ClaudeOAuthUsageFetcher] Parsed resets_at: '%@' → %@", resetsAt, date.description)
            return date
        }

        // 3. Fallback: try original with DateFormatter
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxxxx"
        if let date = formatter.date(from: resetsAt) { return date }

        // 4. Last resort
        NSLog("[ClaudeOAuthUsageFetcher] Failed to parse resets_at: '%@'", resetsAt)
        return ISO8601DateFormatter().date(from: resetsAt)
    }
}

struct OAuthExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?    // in cents
    let usedCredits: Double?     // in cents
    let utilization: Double?     // 0-100
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }

    /// Monthly limit in dollars
    var monthlyLimitDollars: Double? {
        monthlyLimit.map { $0 / 100.0 }
    }

    /// Used credits in dollars
    var usedCreditsDollars: Double? {
        usedCredits.map { $0 / 100.0 }
    }
}

// MARK: - Parsed Result

struct OAuthUsageSnapshot {
    let sessionPercent: Int           // 5-hour window utilization
    let weeklyAllPercent: Int         // 7-day all models
    let weeklySonnetPercent: Int?     // 7-day Sonnet specifically
    let weeklyOpusPercent: Int?       // 7-day Opus specifically
    let sessionResetTime: Date?
    let weeklyAllResetTime: Date?
    let weeklySonnetResetTime: Date?

    // Extra usage (overages)
    let extraUsageEnabled: Bool
    let extraUsageLimitDollars: Double?
    let extraUsageUsedDollars: Double?
    let extraUsagePercent: Int?
}

// MARK: - Fetcher

class ClaudeOAuthUsageFetcher {
    static let shared = ClaudeOAuthUsageFetcher()

    private let credentialStore = ClaudeOAuthCredentialStore.shared
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// How often to auto-refresh (seconds)
    let refreshInterval: TimeInterval = 120

    private var refreshTimer: Timer?
    private var lastSnapshot: OAuthUsageSnapshot?

    private init() {}

    // MARK: - Public API

    /// Fetch usage from the OAuth API. Returns nil if no credentials or request fails.
    func fetchUsage() async -> OAuthUsageSnapshot? {
        guard let credentials = await getValidCredentials() else {
            print("[ClaudeOAuthUsageFetcher] No valid credentials available")
            return nil
        }

        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("[ClaudeOAuthUsageFetcher] Invalid response type")
                return nil
            }

            switch httpResponse.statusCode {
            case 200:
                let snapshot = parseResponse(data)
                if snapshot != nil { lastSnapshot = snapshot }
                return snapshot
            case 401:
                print("[ClaudeOAuthUsageFetcher] 401 Unauthorized - attempting token refresh")
                credentialStore.invalidateCache()
                // Try refresh
                if let refreshToken = credentials.refreshToken {
                    if let newCreds = await credentialStore.refreshToken(using: refreshToken) {
                        return await fetchWithToken(newCreds.accessToken)
                    }
                }
                // Fallback: trigger CLI refresh
                credentialStore.triggerCLIRefresh()
                return nil
            case 429:
                print("[ClaudeOAuthUsageFetcher] 429 Rate limited - trying to parse body, then cached data")
                // Many APIs include usage data even in 429 responses
                if let snapshot = parseResponse(data) {
                    lastSnapshot = snapshot
                    return snapshot
                }
                return lastSnapshot
            default:
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                print("[ClaudeOAuthUsageFetcher] HTTP \(httpResponse.statusCode): \(body)")
                return lastSnapshot
            }
        } catch {
            print("[ClaudeOAuthUsageFetcher] Request error: \(error)")
            return nil
        }
    }

    /// Whether credentials are available (doesn't make a network call)
    var isConfigured: Bool {
        credentialStore.hasCredentials
    }

    // MARK: - Auto-refresh

    func startAutoRefresh(onUpdate: @escaping (OAuthUsageSnapshot) -> Void) {
        stopAutoRefresh()

        // Initial fetch
        Task {
            if let snapshot = await fetchUsage() {
                await MainActor.run { onUpdate(snapshot) }
            }
        }

        // Periodic refresh
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task {
                if let snapshot = await self?.fetchUsage() {
                    await MainActor.run { onUpdate(snapshot) }
                }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Private

    private func getValidCredentials() async -> ClaudeOAuthCredentials? {
        guard let creds = credentialStore.loadCredentials() else {
            return nil
        }

        // If expired, try to refresh
        if creds.isExpired {
            if let refreshToken = creds.refreshToken {
                return await credentialStore.refreshToken(using: refreshToken)
            }
            // No refresh token — trigger CLI refresh and re-read
            credentialStore.triggerCLIRefresh()
            return credentialStore.loadCredentials()
        }

        return creds
    }

    private func fetchWithToken(_ token: String) async -> OAuthUsageSnapshot? {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return nil }
            return parseResponse(data)
        } catch {
            return nil
        }
    }

    private func parseResponse(_ data: Data) -> OAuthUsageSnapshot? {
        do {
            let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)

            let sessionPercent = Int(response.fiveHour?.utilization ?? 0)
            let weeklyAllPercent = Int(response.sevenDay?.utilization ?? 0)
            let weeklySonnetPercent = response.sevenDaySonnet.map { Int($0.utilization) }
            let weeklyOpusPercent = response.sevenDayOpus.map { Int($0.utilization) }

            let extra = response.extraUsage
            let extraEnabled = extra?.isEnabled ?? false

            let snapshot = OAuthUsageSnapshot(
                sessionPercent: sessionPercent,
                weeklyAllPercent: weeklyAllPercent,
                weeklySonnetPercent: weeklySonnetPercent,
                weeklyOpusPercent: weeklyOpusPercent,
                sessionResetTime: response.fiveHour?.resetsAtDate,
                weeklyAllResetTime: response.sevenDay?.resetsAtDate,
                weeklySonnetResetTime: response.sevenDaySonnet?.resetsAtDate,
                extraUsageEnabled: extraEnabled,
                extraUsageLimitDollars: extra?.monthlyLimitDollars,
                extraUsageUsedDollars: extra?.usedCreditsDollars,
                extraUsagePercent: extra?.utilization.map { Int($0) }
            )

            print("[ClaudeOAuthUsageFetcher] Fetched: session=\(sessionPercent)%, weekly=\(weeklyAllPercent)%")
            return snapshot
        } catch {
            print("[ClaudeOAuthUsageFetcher] Parse error: \(error)")
            if let raw = String(data: data, encoding: .utf8) {
                print("[ClaudeOAuthUsageFetcher] Raw response: \(raw.prefix(500))")
            }
            return nil
        }
    }
}
