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
    /// Newer list of limits (weekly_all, weekly_scoped, ...). nil when the API doesn't send it.
    let limits: [OAuthLimit]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case iguanaNecktie = "iguana_necktie"
        case extraUsage = "extra_usage"
        case limits
    }

    // Lenient decoding: a field with an unexpected shape becomes nil instead of
    // failing the whole response. Unknown keys are ignored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try? c.decodeIfPresent(OAuthRateWindow.self, forKey: .fiveHour)
        sevenDay = try? c.decodeIfPresent(OAuthRateWindow.self, forKey: .sevenDay)
        sevenDayOauthApps = try? c.decodeIfPresent(OAuthRateWindow.self, forKey: .sevenDayOauthApps)
        sevenDayOpus = try? c.decodeIfPresent(OAuthRateWindow.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try? c.decodeIfPresent(OAuthRateWindow.self, forKey: .sevenDaySonnet)
        sevenDayCowork = try? c.decodeIfPresent(OAuthRateWindow.self, forKey: .sevenDayCowork)
        iguanaNecktie = try? c.decodeIfPresent(OAuthRateWindow.self, forKey: .iguanaNecktie)
        extraUsage = try? c.decodeIfPresent(OAuthExtraUsage.self, forKey: .extraUsage)
        if let entries = try? c.decodeIfPresent([LossyOAuthLimit].self, forKey: .limits) {
            limits = entries.compactMap { $0.value }
        } else {
            limits = nil
        }
    }
}

/// One entry of the `limits` array.
struct OAuthLimit: Codable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: OAuthLimitScope?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    var resetsAtDate: Date? { resetsAt.flatMap(parseOAuthDate) }

    /// True when this entry describes the 5-hour / session window.
    var isSessionWindow: Bool {
        let k = (kind ?? "").lowercased()
        return (group ?? "").lowercased() == "session" || k.contains("session") || k.contains("five_hour")
    }
}

struct OAuthLimitScope: Codable {
    let model: OAuthLimitModel?
}

struct OAuthLimitModel: Codable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// Decodes a limits entry, yielding nil (instead of throwing) if it has an unexpected shape.
private struct LossyOAuthLimit: Decodable {
    let value: OAuthLimit?
    init(from decoder: Decoder) throws {
        value = try? OAuthLimit(from: decoder)
    }
}

struct OAuthRateWindow: Codable {
    let utilization: Double?  // 0-100 percentage
    let resetsAt: String?     // ISO 8601

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? { resetsAt.flatMap(parseOAuthDate) }
}

/// Parses API timestamps like "2026-03-13T07:00:01.068410+00:00".
func parseOAuthDate(_ resetsAt: String) -> Date? {
    // Strategy: strip fractional seconds (unneeded for reset countdown),
    // then parse with ISO8601DateFormatter which reliably handles +00:00.
    let cleaned = resetsAt.replacingOccurrences(
        of: "\\.\\d+",
        with: "",
        options: .regularExpression
    )

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: cleaned) {
        return date
    }

    // Fallback: try original with DateFormatter
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSxxxxx"
    if let date = formatter.date(from: resetsAt) { return date }

    NSLog("[ClaudeOAuthUsageFetcher] Failed to parse resets_at: '%@'", resetsAt)
    return ISO8601DateFormatter().date(from: resetsAt)
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
    let sessionPercent: Int?          // 5-hour window utilization (nil = no session limit reported)
    let weeklyAllPercent: Int         // 7-day all models
    let weeklySonnetPercent: Int?     // 7-day per-model limit (legacy: Sonnet; now from limits[] weekly_scoped)
    let weeklyOpusPercent: Int?       // 7-day Opus specifically (legacy only)
    let weeklyScopedModelName: String? // Display name for weeklySonnetPercent (e.g. "Fable")
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

            let limits = response.limits

            // Validate: at least one rate window must be present.
            // Error responses (e.g. 429 body: {"error": {...}}) decode successfully
            // with all-nil fields — treat those as invalid rather than 0% data.
            guard !(limits ?? []).isEmpty
               || response.fiveHour?.utilization != nil
               || response.sevenDay?.utilization != nil
               || response.sevenDaySonnet?.utilization != nil
               || response.sevenDayOpus?.utilization != nil
               || response.iguanaNecktie?.utilization != nil else {
                print("[ClaudeOAuthUsageFetcher] Response has no rate windows — likely an error body")
                return nil
            }

            let weeklyAllLimit = limits?.first { $0.kind == "weekly_all" && $0.percent != nil }
            let scopedLimit = limits?.first { $0.kind == "weekly_scoped" && $0.percent != nil }
            let sessionLimit = limits?.first { $0.isSessionWindow && $0.percent != nil }

            // Session (5-hour) window: limits[] entry, else legacy five_hour, else none.
            var sessionPercent: Int?
            let sessionResetTime: Date?
            if let l = sessionLimit, let p = l.percent {
                sessionPercent = normalizeUtilization(p)
                sessionResetTime = l.resetsAtDate
            } else if let w = response.fiveHour, let u = w.utilization {
                sessionPercent = normalizeUtilization(u)
                sessionResetTime = w.resetsAtDate
            } else {
                sessionPercent = nil
                sessionResetTime = nil
            }

            // Weekly all models: limits[] weekly_all, else legacy seven_day.
            var weeklyAllPercent: Int
            let weeklyAllResetTime: Date?
            if let l = weeklyAllLimit, let p = l.percent {
                weeklyAllPercent = normalizeUtilization(p)
                weeklyAllResetTime = l.resetsAtDate
            } else {
                weeklyAllPercent = normalizeUtilization(response.sevenDay?.utilization ?? 0)
                weeklyAllResetTime = response.sevenDay?.resetsAtDate
            }

            // Per-model weekly: limits[] weekly_scoped (named by the API). Legacy
            // seven_day_sonnet/opus are only used when the limits array is absent.
            let weeklySonnetPercent: Int?
            let weeklySonnetResetTime: Date?
            let weeklyOpusPercent: Int?
            let weeklyScopedModelName: String?
            if limits != nil {
                weeklySonnetPercent = scopedLimit?.percent.map { normalizeUtilization($0) }
                weeklySonnetResetTime = scopedLimit?.resetsAtDate
                weeklyScopedModelName = scopedLimit.map { $0.scope?.model?.displayName ?? "Model" }
                weeklyOpusPercent = nil
            } else {
                weeklySonnetPercent = response.sevenDaySonnet?.utilization.map { normalizeUtilization($0) }
                weeklySonnetResetTime = response.sevenDaySonnet?.resetsAtDate
                weeklyScopedModelName = weeklySonnetPercent != nil ? "Sonnet" : nil
                weeklyOpusPercent = response.sevenDayOpus?.utilization.map { normalizeUtilization($0) }
            }

            let fields = "[OAuth FIELDS] session=\(sessionPercent as Any) weekly_all=\(weeklyAllPercent) scoped=\(weeklySonnetPercent as Any) (\(weeklyScopedModelName ?? "-")) opus=\(weeklyOpusPercent as Any) limits=\(limits?.count ?? -1)"
            try? fields.write(toFile: "/tmp/oauth_fields.txt", atomically: true, encoding: .utf8)

            // Incident detection: if aggregate fields are reported as 0 but
            // model-specific fields have real data, the API is partially broken.
            // Preserve cached values instead of overwriting with bogus zeros.
            // A session window that isn't reported at all (nil) is not an incident.
            let hasModelData = (weeklySonnetPercent ?? 0) > 0 || (weeklyOpusPercent ?? 0) > 0
            if hasModelData, let cached = lastSnapshot {
                if sessionPercent == 0, let cachedSession = cached.sessionPercent, cachedSession > 0 {
                    print("[ClaudeOAuthUsageFetcher] Preserving cached session=\(cachedSession)% (API returned 0 during incident)")
                    sessionPercent = cachedSession
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
                weeklyScopedModelName: weeklyScopedModelName,
                sessionResetTime: sessionResetTime,
                weeklyAllResetTime: weeklyAllResetTime,
                weeklySonnetResetTime: weeklySonnetResetTime,
                extraUsageEnabled: extraEnabled,
                extraUsageLimitDollars: extra?.monthlyLimitDollars,
                extraUsageUsedDollars: extra?.usedCreditsDollars,
                extraUsagePercent: extra?.utilization.map { Int($0) }
            )

            print("[ClaudeOAuthUsageFetcher] Fetched: session=\(sessionPercent.map { "\($0)%" } ?? "none"), weekly=\(weeklyAllPercent)%")
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
