//
//  UsageCalculator.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import Foundation

/// Calculates usage percentages from token data
class UsageCalculator {

    // MARK: - Token Estimates

    // Estimated tokens per "hour" of usage based on typical Claude Pro usage patterns
    // These are rough estimates - actual rates vary based on conversation complexity
    static let tokensPerHour: [String: Int] = [
        "sonnet": 50_000,    // ~50k tokens per "usage hour" for Sonnet
        "opus": 30_000,      // Opus uses quota faster
        "haiku": 100_000     // Haiku uses less quota
    ]

    // Weekly limit estimates (Pro plan)
    // These represent the approximate number of "usage hours" per week
    static let weeklyLimitHours: [String: Double] = [
        "sonnet": 60.0,   // ~60 hours for Sonnet per week
        "opus": 6.0,      // ~6 hours for Opus per week (limited)
        "all": 80.0       // Combined all models estimate
    ]

    // Session limit (messages per 5-hour window)
    static let sessionLimitMessages = 45  // Approximate for typical message sizes

    // MARK: - Calculate from Parsed Usage

    func calculatePercentages(from usage: ParsedCodeUsage) -> CalculatedUsage {
        // Calculate estimated hours used
        let sonnetHours = Double(usage.sonnetTokens) / Double(Self.tokensPerHour["sonnet"] ?? 50_000)
        let opusHours = Double(usage.opusTokens) / Double(Self.tokensPerHour["opus"] ?? 30_000)
        let haikuHours = Double(usage.haikuTokens) / Double(Self.tokensPerHour["haiku"] ?? 100_000)

        // Calculate weekly percentages
        let sonnetPercent = min(100, Int((sonnetHours / Self.weeklyLimitHours["sonnet"]!) * 100))
        let opusPercent = min(100, Int((opusHours / Self.weeklyLimitHours["opus"]!) * 100))

        // All models combined (weighted estimate)
        let totalHours = sonnetHours + opusHours + haikuHours
        let allModelsPercent = min(100, Int((totalHours / Self.weeklyLimitHours["all"]!) * 100))

        // Weekly tokens to percent (rough estimate: 4M tokens = 100%)
        let weeklyTokensPercent = min(100, Int((Double(usage.weeklyTokens) / 4_000_000) * 100))

        return CalculatedUsage(
            weeklyAllPercent: allModelsPercent,
            weeklySonnetPercent: sonnetPercent,
            weeklyOpusPercent: opusPercent,
            weeklyTokens: usage.weeklyTokens,
            todayTokens: usage.todayTokens,
            totalTokensAllTime: usage.totalTokensAllTime,
            sonnetHours: sonnetHours,
            opusHours: opusHours,
            haikuHours: haikuHours,
            totalSessions: usage.totalSessions,
            totalMessages: usage.totalMessages,
            lastUpdated: usage.lastUpdated
        )
    }

    // MARK: - Calculate Weekly Reset Time

    /// Returns the next Tuesday 9 AM in user's timezone (typical reset day)
    func nextWeeklyResetTime() -> Date {
        let calendar = Calendar.current
        let now = Date()

        // Find next Tuesday at 9 AM
        if let nextTuesday = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 9, minute: 0, weekday: 3),
            matchingPolicy: .nextTime
        ) {
            return nextTuesday
        }

        // Fallback: 7 days from now
        return calendar.date(byAdding: .day, value: 7, to: now) ?? now
    }

    /// Returns estimated session reset time (5 hours from last heavy usage)
    func estimatedSessionResetTime(lastHeavyUsage: Date?) -> Date {
        let fiveHours: TimeInterval = 5 * 3600

        if let lastUsage = lastHeavyUsage {
            let resetTime = lastUsage.addingTimeInterval(fiveHours)
            if resetTime > Date() {
                return resetTime
            }
        }

        // If no known heavy usage or reset already passed, estimate from now
        return Date().addingTimeInterval(fiveHours)
    }

    // MARK: - Format Helpers

    func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        } else {
            return "\(tokens)"
        }
    }

    func formatHours(_ hours: Double) -> String {
        if hours < 1 {
            let minutes = Int(hours * 60)
            return "\(minutes)m"
        } else if hours < 10 {
            return String(format: "%.1fh", hours)
        } else {
            return String(format: "%.0fh", hours)
        }
    }
}

// MARK: - Calculated Usage Result

struct CalculatedUsage {
    let weeklyAllPercent: Int
    let weeklySonnetPercent: Int
    let weeklyOpusPercent: Int
    let weeklyTokens: Int
    let todayTokens: Int
    let totalTokensAllTime: Int
    let sonnetHours: Double
    let opusHours: Double
    let haikuHours: Double
    let totalSessions: Int
    let totalMessages: Int
    let lastUpdated: Date

    var totalHours: Double {
        return sonnetHours + opusHours + haikuHours
    }

    var hasData: Bool {
        return totalTokensAllTime > 0 || weeklyTokens > 0
    }

    static var empty: CalculatedUsage {
        return CalculatedUsage(
            weeklyAllPercent: 0,
            weeklySonnetPercent: 0,
            weeklyOpusPercent: 0,
            weeklyTokens: 0,
            todayTokens: 0,
            totalTokensAllTime: 0,
            sonnetHours: 0,
            opusHours: 0,
            haikuHours: 0,
            totalSessions: 0,
            totalMessages: 0,
            lastUpdated: Date()
        )
    }
}
