//
//  ClaudeUsageService.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import Foundation
import Combine

// MARK: - Rate Limit Prediction Models

enum WarningLevel: Int, Comparable {
    case none = 0      // < 70%
    case caution = 1   // 70-84%
    case warning = 2   // 85-94%
    case critical = 3  // 95%+

    static func < (lhs: WarningLevel, rhs: WarningLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func from(percent: Int) -> WarningLevel {
        switch percent {
        case 0..<70: return .none
        case 70..<85: return .caution
        case 85..<95: return .warning
        default: return .critical
        }
    }
}

struct RateLimitPrediction {
    let currentPercent: Int
    let velocityPerHour: Double?      // tokens/hour (nil if insufficient data)
    let estimatedTimeToLimit: TimeInterval?
    let warningLevel: WarningLevel
    let resetTime: Date?

    var formattedTimeRemaining: String? {
        guard let time = estimatedTimeToLimit, time > 0 else { return nil }

        if time < 3600 {
            return "~\(Int(time / 60))m left"
        } else if time < 86400 {
            return "~\(Int(time / 3600))h left"
        } else {
            return "~\(Int(time / 86400))d left"
        }
    }

    static let empty = RateLimitPrediction(
        currentPercent: 0,
        velocityPerHour: nil,
        estimatedTimeToLimit: nil,
        warningLevel: .none,
        resetTime: nil
    )
}

/// Main service that orchestrates all usage data sources and provides unified updates
class ClaudeUsageService: ObservableObject {
    static let shared = ClaudeUsageService()

    // MARK: - Debug Logging

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func ts() -> String {
        return Self.timestampFormatter.string(from: Date())
    }

    // MARK: - Published Properties

    @Published private(set) var currentUsage: ClaudeUsageData = .empty
    @Published private(set) var isInitialized: Bool = false
    @Published private(set) var hasCodeData: Bool = false
    @Published private(set) var hasOAuthData: Bool = false
    @Published private(set) var weeklyPrediction: RateLimitPrediction = .empty
    @Published private(set) var sessionPrediction: RateLimitPrediction = .empty
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastRefreshError: String? = nil
    @Published private(set) var isInitialFetchInProgress: Bool = false

    private let logMonitor = ClaudeLogMonitor.shared
    private let oauthFetcher = ClaudeOAuthUsageFetcher.shared
    private let parser = JSONLParser()
    private let calculator = UsageCalculator()

    private var cancellables = Set<AnyCancellable>()
    private var midnightTimer: Timer?
    private var tokenRefreshTimer: Timer?

    // MARK: - Initialization

    private init() {}

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start() {
        print("[ClaudeUsageService] Starting...")

        // Start OAuth usage fetching (if credentials available)
        if oauthFetcher.isConfigured {
            print("[ClaudeUsageService] OAuth credentials found, starting API polling")
            hasOAuthData = true
            isInitialFetchInProgress = true
            oauthFetcher.startAutoRefresh(
                onUpdate: { [weak self] snapshot in
                    self?.handleOAuthUsageData(snapshot)
                },
                onInitialFetchComplete: { [weak self] in
                    guard let self = self else { return }
                    self.isInitialFetchInProgress = false
                    // If we never got data, credentials were bad — show disconnected, not loading
                    if !self.currentUsage.hasOAuthData {
                        self.hasOAuthData = false
                        print("[ClaudeUsageService] Initial fetch failed — marking as disconnected")
                    }
                }
            )
        } else {
            print("[ClaudeUsageService] No OAuth credentials - will use extension/local data only")
        }

        // Start file monitoring
        logMonitor.startMonitoring { [weak self] in
            self?.refreshCodeUsage()
            self?.refreshTokenCache()
        }

        // Initial load of code usage
        refreshCodeUsage()

        // Finalize yesterday's token count and schedule future midnight snapshots
        DailyTokenCache.shared.finalizeYesterday()
        scheduleMidnightSnapshot()

        // Build/update the JSONL token cache in background.
        // First launch: parses all JSONL files (one-time, ~1-2 min).
        // Subsequent launches: only re-parses today's files (seconds).
        refreshTokenCache()

        // Refresh token cache every 5 minutes to keep "Today" count fresh
        tokenRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshTokenCache()
        }

        isInitialized = true
        print("[ClaudeUsageService] Started successfully")
    }

    func stop() {
        logMonitor.stopMonitoring()
        oauthFetcher.stopAutoRefresh()
        midnightTimer?.invalidate()
        midnightTimer = nil
        tokenRefreshTimer?.invalidate()
        tokenRefreshTimer = nil
        cancellables.removeAll()
        print("[ClaudeUsageService] Stopped")
    }

    // MARK: - Token Cache Refresh

    private func refreshTokenCache() {
        let dir = parser.projectsPath
        Task.detached(priority: .utility) {
            let _ = await DailyTokenCache.shared.update(projectsDir: dir)
            await MainActor.run {
                NotificationCenter.default.post(name: .claudeUsageDataReceived, object: nil)
            }
        }
    }

    // MARK: - Midnight Snapshot

    private func scheduleMidnightSnapshot() {
        midnightTimer?.invalidate()
        let cal = Calendar.current
        let now = Date()
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now)) else { return }
        let fireAt = tomorrow.addingTimeInterval(60)  // 12:01 AM
        let timer = Timer(fireAt: fireAt, interval: 0, target: self,
                          selector: #selector(handleMidnight), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        midnightTimer = timer
    }

    @objc private func handleMidnight() {
        DailyTokenCache.shared.finalizeYesterday()
        scheduleMidnightSnapshot()
        print("[ClaudeUsageService] Midnight snapshot taken")
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshError = nil
        ClaudeOAuthCredentialStore.shared.invalidateCache()
        refreshCodeUsage()
        // Also trigger an OAuth refresh
        Task {
            let startTime = Date()
            let snapshot = await oauthFetcher.fetchUsage()

            // Ensure spinner shows for at least 0.8s so user sees feedback
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < 0.8 {
                try? await Task.sleep(nanoseconds: UInt64((0.8 - elapsed) * 1_000_000_000))
            }

            await MainActor.run {
                if let snapshot = snapshot {
                    self.handleOAuthUsageData(snapshot)
                    self.lastRefreshError = nil
                    print("[ClaudeUsageService] refresh() succeeded - session=\(snapshot.sessionPercent)%, weekly=\(snapshot.weeklyAllPercent)%")
                } else {
                    self.lastRefreshError = "Failed to fetch usage data. Check that `claude /login` has been run."
                    print("[ClaudeUsageService] refresh() failed - fetchUsage returned nil")
                }
                self.isRefreshing = false
            }
        }
    }

    /// Re-check for OAuth credentials and start polling if found.
    /// Call this after user completes login.
    func connectOAuth() {
        ClaudeOAuthCredentialStore.shared.invalidateCache()
        if oauthFetcher.isConfigured {
            print("[ClaudeUsageService] OAuth credentials found after connect, starting polling")
            oauthFetcher.startAutoRefresh { [weak self] snapshot in
                self?.handleOAuthUsageData(snapshot)
            }
        }
    }

    // MARK: - Code Usage (from ~/.claude/ logs)

    private func refreshCodeUsage() {
        print("[ClaudeUsageService] Refreshing code usage...")
        print("[ClaudeUsageService] Claude directory exists: \(parser.claudeDirectoryExists())")
        print("[ClaudeUsageService] Stats cache exists: \(parser.statsCacheExists())")
        print("[ClaudeUsageService] Stats cache path: \(parser.statsCachePath.path)")

        var codeCalculated: CalculatedUsage?

        // Try to read from stats-cache.json first (faster, pre-aggregated)
        if let statsCache = parser.parseStatsCache() {
            let parsedUsage = parser.usageFromStatsCache(statsCache)
            codeCalculated = calculator.calculatePercentages(from: parsedUsage)
            print("[ClaudeUsageService] Loaded from stats-cache.json:")
            print("  - Weekly tokens: \(parsedUsage.weeklyTokens)")
            print("  - Today tokens: \(parsedUsage.todayTokens)")
            print("  - Total tokens all time: \(parsedUsage.totalTokensAllTime)")
            print("  - Sonnet tokens: \(parsedUsage.sonnetTokens)")
            print("  - Opus tokens: \(parsedUsage.opusTokens)")
            print("  - Total sessions: \(parsedUsage.totalSessions)")
        } else {
            print("[ClaudeUsageService] stats-cache.json not available, trying JSONL fallback...")
            // Fallback: parse JSONL files directly
            let entries = parser.parseAllProjectLogs()
            if !entries.isEmpty {
                let parsedUsage = parser.usageFromLogEntries(entries)
                codeCalculated = calculator.calculatePercentages(from: parsedUsage)
                print("[ClaudeUsageService] Parsed \(entries.count) log entries:")
                print("  - Weekly tokens: \(parsedUsage.weeklyTokens)")
                print("  - Today tokens: \(parsedUsage.todayTokens)")
            } else {
                print("[ClaudeUsageService] No Claude Code logs found in projects directory")
            }
        }

        if let calc = codeCalculated {
            print("[ClaudeUsageService] Calculated usage:")
            print("  - Weekly all percent: \(calc.weeklyAllPercent)%")
            print("  - Weekly sonnet percent: \(calc.weeklySonnetPercent)%")
            print("  - Has data: \(calc.hasData)")
        } else {
            print("[ClaudeUsageService] No calculated usage - codeCalculated is nil")
        }

        // Update usage data with code values
        updateUsageData(codeUsage: codeCalculated)
    }

    // MARK: - OAuth Usage (from Anthropic API)

    private func handleOAuthUsageData(_ snapshot: OAuthUsageSnapshot) {
        print("[ClaudeUsageService \(ts())] OAUTH RECEIVED: session=\(snapshot.sessionPercent)%, weekly=\(snapshot.weeklyAllPercent)%")
        updateUsageData(oauthUsage: snapshot)
    }

    // MARK: - Merge and Update

    private func updateUsageData(codeUsage: CalculatedUsage? = nil, oauthUsage: OAuthUsageSnapshot? = nil) {
        print("[ClaudeUsageService \(ts())] updateUsageData called - codeUsage: \(codeUsage != nil), oauthUsage: \(oauthUsage != nil)")

        var updatedUsage = currentUsage
        var hasChanges = false

        // Update code usage fields
        if let code = codeUsage {
            // Only mark as changed if values actually differ
            let newSonnetTokens = Int(code.sonnetHours * Double(UsageCalculator.tokensPerHour["sonnet"] ?? 50_000))
            let newOpusTokens = Int(code.opusHours * Double(UsageCalculator.tokensPerHour["opus"] ?? 30_000))

            if updatedUsage.codeWeeklyTokens != code.weeklyTokens
                || updatedUsage.codeTodayTokens != code.todayTokens
                || updatedUsage.codeSonnetTokens != newSonnetTokens
                || updatedUsage.codeOpusTokens != newOpusTokens {

                updatedUsage.codeWeeklyTokens = code.weeklyTokens
                updatedUsage.codeTodayTokens = code.todayTokens
                updatedUsage.codeSonnetTokens = newSonnetTokens
                updatedUsage.codeOpusTokens = newOpusTokens
                hasChanges = true
                print("[ClaudeUsageService \(ts())] Code data changed - weeklyTokens: \(code.weeklyTokens)")
            }
            hasCodeData = code.hasData
        }

        // Update OAuth usage fields
        if let oauth = oauthUsage {
            updatedUsage.oauthSessionPercent = oauth.sessionPercent
            updatedUsage.oauthWeeklyAllPercent = oauth.weeklyAllPercent
            updatedUsage.oauthWeeklySonnetPercent = oauth.weeklySonnetPercent
            updatedUsage.oauthWeeklyOpusPercent = oauth.weeklyOpusPercent
            updatedUsage.oauthSessionResetTime = oauth.sessionResetTime
            updatedUsage.oauthWeeklyAllResetTime = oauth.weeklyAllResetTime
            updatedUsage.oauthWeeklySonnetResetTime = oauth.weeklySonnetResetTime
            updatedUsage.oauthExtraUsageEnabled = oauth.extraUsageEnabled
            updatedUsage.oauthExtraUsageLimitDollars = oauth.extraUsageLimitDollars
            updatedUsage.oauthExtraUsageUsedDollars = oauth.extraUsageUsedDollars
            updatedUsage.oauthExtraUsagePercent = oauth.extraUsagePercent
            updatedUsage.isOAuthConnected = true
            hasOAuthData = true
            hasChanges = true
            print("[ClaudeUsageService \(ts())] OAuth data updated - session=\(oauth.sessionPercent)%, weekly=\(oauth.weeklyAllPercent)%")
        }

        // Skip posting if nothing changed (prevents stale code-only updates from clobbering fresh web data)
        guard hasChanges else {
            print("[ClaudeUsageService \(ts())] No changes detected, skipping notification")
            return
        }

        // NOTE: Code data only has token counts, not actual rate limit percentages.
        // Percentage bars require OAuth API connection.

        updatedUsage.lastUpdated = Date()

        print("[ClaudeUsageService \(ts())] STORING: session=\(updatedUsage.oauthSessionPercent ?? -1)%, weekly=\(updatedUsage.oauthWeeklyAllPercent ?? -1)%")

        // Update on main thread
        DispatchQueue.main.async {
            self.currentUsage = updatedUsage
            self.updatePredictions(from: updatedUsage)
            self.postNotification()
            UsageHistoryStore.shared.record(self.currentUsage)
            NotificationCenter.default.post(name: .usageHistoryUpdated, object: nil)
            print("[ClaudeUsageService \(self.ts())] POSTED: session=\(self.currentUsage.oauthSessionPercent ?? -1)%, weekly=\(self.currentUsage.oauthWeeklyAllPercent ?? -1)%")
        }
    }

    // MARK: - Predictions

    private func updatePredictions(from usage: ClaudeUsageData) {
        let weeklyPercent = usage.oauthWeeklyAllPercent
        let weeklyReset = usage.displayWeeklyAllResetTime
        let sessionPercent = usage.oauthSessionPercent
        let sessionReset = usage.displaySessionResetTime

        // Update weekly prediction
        if let percent = weeklyPercent {
            weeklyPrediction = calculatePrediction(
                percent: percent,
                resetTime: weeklyReset
            )
        } else {
            weeklyPrediction = .empty
        }

        // Update session prediction
        if let percent = sessionPercent {
            sessionPrediction = calculatePrediction(
                percent: percent,
                resetTime: sessionReset
            )
        } else {
            sessionPrediction = .empty
        }
    }

    private func calculatePrediction(percent: Int, resetTime: Date?) -> RateLimitPrediction {
        let warningLevel = WarningLevel.from(percent: percent)

        // Simple time-to-limit estimation
        // In a real implementation, we'd track usage velocity over time
        var estimatedTimeToLimit: TimeInterval? = nil

        if percent > 0 && percent < 100 {
            // Rough heuristic: assume current pace continues
            // If at X%, estimate time to reach 100%
            let remaining = 100 - percent
            let estimatedHoursPerPercent = 0.3  // ~18 minutes per percent point as baseline

            estimatedTimeToLimit = Double(remaining) * estimatedHoursPerPercent * 3600
        }

        return RateLimitPrediction(
            currentPercent: percent,
            velocityPerHour: nil,  // Would require tracking over time
            estimatedTimeToLimit: estimatedTimeToLimit,
            warningLevel: warningLevel,
            resetTime: resetTime
        )
    }

    private func postNotification() {
        NotificationCenter.default.post(
            name: .claudeUsageDataReceived,
            object: nil,
            userInfo: ["data": currentUsage]
        )
    }

    // MARK: - Status

    var statusDescription: String {
        var parts: [String] = []

        if hasOAuthData {
            parts.append("API: connected")
        } else {
            parts.append("API: not connected")
        }

        if hasCodeData {
            parts.append("Code: \(calculator.formatTokenCount(currentUsage.codeWeeklyTokens ?? 0)) this week")
        } else if parser.claudeDirectoryExists() {
            parts.append("Code: no usage yet")
        } else {
            parts.append("Code: not installed")
        }

        return parts.joined(separator: " | ")
    }
}
