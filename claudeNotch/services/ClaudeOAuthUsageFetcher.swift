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
    let sevenDayCowork: OAuthRateWindow?
    let iguanaNecktie: OAuthRateWindow?
    let extraUsage: OAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
    }
}

struct OAuthRateWindow: Codable {
    let utilization: Double  // 0-100 percentage
    let resetsAt: String?     // ISO 8601

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        // API format: "2026-03-13T07:00:01.068410+00:00"
        // Strategy: strip fractional seconds (unneeded for reset countdown),
        // then parse with ISO8601DateFormatter which reliably handles +00:00.

        // 1. Strip fractional seconds: ".068410" → ""
        let cleaned = (resetsAt ?? "").replacingOccurrences(
            of: "\\.\\d+",
            with: "",
            options: .regularExpression
        )

        // 2. Parse cleaned string with ISO8601DateFormatter
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: cleaned) {
            NSLog("[ClaudeOAuthUsageFetcher] Parsed resets_at: '%@' → %@", resetsAt ?? "N/A", date.description)
            return date
        }

        // 3. Fallback: try original with DateFormatter
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxxxx"
        if let resetsAt, let date = formatter.date(from: resetsAt) { return date }

        // 4. Last resort
        NSLog("[ClaudeOAuthUsageFetcher] Failed to parse resets_at: '%@'", resetsAt ?? "N/A")
        guard let resetsAt else { return nil }
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
    /// Skip counter for 429 backoff — each 429 sets this to 2, skipping 2 polls (~4 min cooldown)
    private var pollSkipsRemaining = 0

    private init() {}

    // MARK: - Public API

    /// Fetch usage from the OAuth API. Returns nil if no credentials or request fails.
    func fetchUsage() async -> OAuthUsageSnapshot? {
        // Backoff: skip this poll if we're cooling down from a 429
        if pollSkipsRemaining > 0 {
            pollSkipsRemaining -= 1
            print("[ClaudeOAuthUsageFetcher] Backing off (\(pollSkipsRemaining) skips remaining)")
            return lastSnapshot
        }

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
                pollSkipsRemaining = 0  // Reset backoff on success
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
                pollSkipsRemaining = 2  // Skip next 2 polls (~4 min cooldown)
                print("[ClaudeOAuthUsageFetcher] 429 Rate limited - backing off for \(pollSkipsRemaining) polls, returning cached data")
                // Try to parse body (some APIs include data in 429), otherwise use cache
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

    func startAutoRefresh(onUpdate: @escaping (OAuthUsageSnapshot) -> Void,
                          onInitialFetchComplete: (() -> Void)? = nil) {
        stopAutoRefresh()

        // Initial fetch — always calls onInitialFetchComplete so callers can exit loading state
        Task {
            let snapshot = await fetchUsage()
            await MainActor.run {
                if let snapshot = snapshot { onUpdate(snapshot) }
                onInitialFetchComplete?()
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

    /// Normalizes a utilization value to integer percentage (0–100).
    /// The API returns utilization as percentages (0–100).
    private func normalizeUtilization(_ value: Double) -> Int {
        return min(100, max(0, Int(value.rounded())))
    }

    private func parseResponse(_ data: Data) -> OAuthUsageSnapshot? {
        // DIAGNOSTIC — write raw response to /tmp/oauth_debug.json
        if let raw = String(data: data, encoding: .utf8) {
            try? raw.write(toFile: "/tmp/oauth_debug.json", atomically: true, encoding: .utf8)
        }
        do {
            let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)

            // Validate: at least one rate window must be present.
            // Error responses (e.g. 429 body: {"error": {...}}) decode successfully
            // with all-nil fields — treat those as invalid rather than 0% data.
            guard response.fiveHour != nil
               || response.sevenDay != nil
               || response.sevenDaySonnet != nil
               || response.sevenDayOpus != nil
               || response.iguanaNecktie != nil else {
                print("[ClaudeOAuthUsageFetcher] Response has no rate windows — likely an error body")
                return nil
            }

            let fields = "[OAuth FIELDS] five_hour=\(response.fiveHour?.utilization as Any) seven_day=\(response.sevenDay?.utilization as Any) iguana_necktie=\(response.iguanaNecktie?.utilization as Any) sonnet=\(response.sevenDaySonnet?.utilization as Any) opus=\(response.sevenDayOpus?.utilization as Any) oauth_apps=\(response.sevenDayOauthApps?.utilization as Any)"
            try? fields.write(toFile: "/tmp/oauth_fields.txt", atomically: true, encoding: .utf8)

            var sessionPercent = normalizeUtilization(response.fiveHour?.utilization ?? 0)
            var weeklyAllPercent = normalizeUtilization(response.sevenDay?.utilization ?? 0)
            let weeklySonnetPercent = response.sevenDaySonnet.map { normalizeUtilization($0.utilization) }
            let weeklyOpusPercent = response.sevenDayOpus.map { normalizeUtilization($0.utilization) }

            // Incident detection: if aggregate fields (five_hour/seven_day) are 0 but
            // model-specific fields have real data, the API is partially broken.
            // Preserve cached values instead of overwriting with bogus zeros.
            let hasModelData = (weeklySonnetPercent ?? 0) > 0 || (weeklyOpusPercent ?? 0) > 0
            if hasModelData, let cached = lastSnapshot {
                if sessionPercent == 0 && cached.sessionPercent > 0 {
                    print("[ClaudeOAuthUsageFetcher] Preserving cached session=\(cached.sessionPercent)% (API returned 0 during incident)")
                    sessionPercent = cached.sessionPercent
                }
                if weeklyAllPercent == 0 && cached.weeklyAllPercent > 0 {
                    print("[ClaudeOAuthUsageFetcher] Preserving cached weekly=\(cached.weeklyAllPercent)% (API returned 0 during incident)")
                    weeklyAllPercent = cached.weeklyAllPercent
                }
            }

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
