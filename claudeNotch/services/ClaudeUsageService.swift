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
    @Published private(set) var hasWebData: Bool = false
    @Published private(set) var hasOAuthData: Bool = false
    @Published private(set) var weeklyPrediction: RateLimitPrediction = .empty
    @Published private(set) var sessionPrediction: RateLimitPrediction = .empty

    // MARK: - Private Properties

    private let logMonitor = ClaudeLogMonitor.shared
    private let webSocketServer = WebSocketServer.shared
    private let oauthFetcher = ClaudeOAuthUsageFetcher.shared
    private let parser = JSONLParser()
    private let calculator = UsageCalculator()

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {}

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start() {
        print("[ClaudeUsageService] Starting...")

        // Set up WebSocket server callback
        webSocketServer.onUsageReceived = { [weak self] webData in
            self?.handleWebUsageData(webData)
        }

        // Start WebSocket server
        webSocketServer.start()

        // Start OAuth usage fetching (if credentials available)
        if oauthFetcher.isConfigured {
            print("[ClaudeUsageService] OAuth credentials found, starting API polling")
            hasOAuthData = true  // Show "Connected" in Settings immediately; actual data sets usageData.hasOAuthData
            oauthFetcher.startAutoRefresh { [weak self] snapshot in
                self?.handleOAuthUsageData(snapshot)
            }
        } else {
            print("[ClaudeUsageService] No OAuth credentials - will use extension/local data only")
        }

        // Start file monitoring
        logMonitor.startMonitoring { [weak self] in
            self?.refreshCodeUsage()
        }

        // Initial load of code usage
        refreshCodeUsage()

        isInitialized = true
        print("[ClaudeUsageService] Started successfully")
    }

    func stop() {
        logMonitor.stopMonitoring()
        webSocketServer.stop()
        oauthFetcher.stopAutoRefresh()
        cancellables.removeAll()
        print("[ClaudeUsageService] Stopped")
    }

    func refresh() {
        refreshCodeUsage()
        // Also trigger an OAuth refresh
        Task {
            if let snapshot = await oauthFetcher.fetchUsage() {
                await MainActor.run {
                    self.handleOAuthUsageData(snapshot)
                }
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

    // MARK: - Web Usage (from browser extension)

    private func handleWebUsageData(_ webData: WebUsageData) {
        print("[ClaudeUsageService \(ts())] WEB RECEIVED: session=\(webData.sessionPercent)%, weekly=\(webData.weeklyAllPercent)%")

        // Update usage data with web values
        updateUsageData(webUsage: webData)
    }

    // MARK: - OAuth Usage (from Anthropic API)

    private func handleOAuthUsageData(_ snapshot: OAuthUsageSnapshot) {
        print("[ClaudeUsageService \(ts())] OAUTH RECEIVED: session=\(snapshot.sessionPercent)%, weekly=\(snapshot.weeklyAllPercent)%")
        updateUsageData(oauthUsage: snapshot)
    }

    // MARK: - Merge and Update

    private func updateUsageData(codeUsage: CalculatedUsage? = nil, webUsage: WebUsageData? = nil, oauthUsage: OAuthUsageSnapshot? = nil) {
        print("[ClaudeUsageService \(ts())] updateUsageData called - codeUsage: \(codeUsage != nil), webUsage: \(webUsage != nil), oauthUsage: \(oauthUsage != nil)")

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

        // Update web usage fields - ALWAYS post web updates immediately
        if let web = webUsage {
            updatedUsage.sessionPercent = web.sessionPercent
            updatedUsage.weeklyAllPercent = web.weeklyAllPercent
            updatedUsage.weeklySonnetPercent = web.weeklySonnetPercent
            updatedUsage.sessionResetTime = web.sessionResetDate
            updatedUsage.weeklyAllResetTime = web.weeklyAllResetDate
            updatedUsage.weeklySonnetResetTime = web.weeklySonnetResetDate
            updatedUsage.accountType = web.accountType
            updatedUsage.isConnected = true
            hasWebData = true
            hasChanges = true  // Always post web updates
            print("[ClaudeUsageService \(ts())] Web data updated - session=\(web.sessionPercent)%, weekly=\(web.weeklyAllPercent)%")
        }

        // Update OAuth usage fields (real API data - highest priority)
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

        // NOTE: We do NOT set percentages from code data because:
        // - Code data only has token counts, not actual rate limit percentages
        // - The UsageCalculator estimates are fabricated guesses, not real limits
        // - Real percentages (27%, 0%, etc.) only come from claude.ai via browser extension
        // Code-only mode shows token counts; percentage bars require browser extension

        updatedUsage.lastUpdated = Date()

        print("[ClaudeUsageService \(ts())] STORING: session=\(updatedUsage.sessionPercent ?? -1)%, weekly=\(updatedUsage.weeklyAllPercent ?? -1)%")

        // Update on main thread
        DispatchQueue.main.async {
            self.currentUsage = updatedUsage
            self.updatePredictions(from: updatedUsage)
            self.postNotification()
            UsageHistoryStore.shared.record(self.currentUsage)
            NotificationCenter.default.post(name: .usageHistoryUpdated, object: nil)
            print("[ClaudeUsageService \(self.ts())] POSTED: session=\(self.currentUsage.sessionPercent ?? -1)%, weekly=\(self.currentUsage.weeklyAllPercent ?? -1)%")
        }
    }

    // MARK: - Predictions

    private func updatePredictions(from usage: ClaudeUsageData) {
        // Prefer OAuth data, fallback to web extension data
        let weeklyPercent = usage.oauthWeeklyAllPercent ?? usage.weeklyAllPercent
        let weeklyReset = usage.displayWeeklyAllResetTime
        let sessionPercent = usage.oauthSessionPercent ?? usage.sessionPercent
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
        } else if hasWebData {
            parts.append("Web: connected")
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
