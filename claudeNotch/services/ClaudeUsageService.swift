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
    @Published private(set) var weeklyPrediction: RateLimitPrediction = .empty
    @Published private(set) var sessionPrediction: RateLimitPrediction = .empty

    // MARK: - Private Properties

    private let logMonitor = ClaudeLogMonitor.shared
    private let webSocketServer = WebSocketServer.shared
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
        cancellables.removeAll()
        print("[ClaudeUsageService] Stopped")
    }

    func refresh() {
        refreshCodeUsage()
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

    // MARK: - Merge and Update

    private func updateUsageData(codeUsage: CalculatedUsage? = nil, webUsage: WebUsageData? = nil) {
        print("[ClaudeUsageService \(ts())] updateUsageData called - codeUsage: \(codeUsage != nil), webUsage: \(webUsage != nil)")

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
            print("[ClaudeUsageService \(self.ts())] POSTED: session=\(self.currentUsage.sessionPercent ?? -1)%, weekly=\(self.currentUsage.weeklyAllPercent ?? -1)%")
        }
    }

    // MARK: - Predictions

    private func updatePredictions(from usage: ClaudeUsageData) {
        // Update weekly prediction
        if let percent = usage.weeklyAllPercent {
            weeklyPrediction = calculatePrediction(
                percent: percent,
                resetTime: usage.weeklyAllResetTime
            )
        } else {
            weeklyPrediction = .empty
        }

        // Update session prediction
        if let percent = usage.sessionPercent {
            sessionPrediction = calculatePrediction(
                percent: percent,
                resetTime: usage.sessionResetTime
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

        if hasWebData {
            parts.append("Web: connected")
        } else {
            parts.append("Web: not connected")
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
