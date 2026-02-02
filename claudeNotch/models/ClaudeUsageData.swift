//
//  ClaudeUsageData.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import SwiftUI
import Foundation

struct ClaudeUsageData: Codable, Equatable {
    // Web usage (from browser extension via WebSocket)
    var sessionPercent: Int?
    var weeklyAllPercent: Int?
    var weeklySonnetPercent: Int?
    var sessionResetTime: Date?
    var weeklyAllResetTime: Date?
    var weeklySonnetResetTime: Date?

    // Code usage (from ~/.claude/ logs)
    var codeWeeklyTokens: Int?
    var codeTodayTokens: Int?
    var codeSonnetTokens: Int?
    var codeOpusTokens: Int?

    // Metadata
    var accountType: String?
    var isConnected: Bool
    var lastUpdated: Date

    // MARK: - Empty Initial State

    static var empty: ClaudeUsageData {
        ClaudeUsageData(
            sessionPercent: nil,
            weeklyAllPercent: nil,
            weeklySonnetPercent: nil,
            sessionResetTime: nil,
            weeklyAllResetTime: nil,
            weeklySonnetResetTime: nil,
            codeWeeklyTokens: nil,
            codeTodayTokens: nil,
            codeSonnetTokens: nil,
            codeOpusTokens: nil,
            accountType: nil,
            isConnected: false,
            lastUpdated: Date()
        )
    }

    // MARK: - Computed Properties

    var hasWebData: Bool {
        return sessionPercent != nil || weeklyAllPercent != nil
    }

    var hasCodeData: Bool {
        return codeWeeklyTokens != nil && codeWeeklyTokens! > 0
    }

    var hasAnyData: Bool {
        return hasWebData || hasCodeData
    }

    // Display-friendly percentages (default to 0 if nil)
    var displaySessionPercent: Int { sessionPercent ?? 0 }
    var displayWeeklyAllPercent: Int { weeklyAllPercent ?? 0 }
    var displayWeeklySonnetPercent: Int { weeklySonnetPercent ?? 0 }

    // MARK: - Color Helpers

    /// Returns color based on usage percentage thresholds
    func colorForPercent(_ percent: Int) -> Color {
        switch percent {
        case 0..<50:
            return Color(red: 16/255, green: 185/255, blue: 129/255)   // Green #10B981
        case 50..<80:
            return Color(red: 245/255, green: 158/255, blue: 11/255)   // Yellow #F59E0B
        case 80..<95:
            return Color(red: 249/255, green: 115/255, blue: 22/255)   // Orange #F97316
        default:
            return Color(red: 239/255, green: 68/255, blue: 68/255)    // Red #EF4444
        }
    }

    /// Returns color for optional percent
    func colorForOptionalPercent(_ percent: Int?) -> Color {
        guard let p = percent else {
            return Color.gray
        }
        return colorForPercent(p)
    }

    // MARK: - Time Formatting

    /// Format reset time as human-readable string
    static func formatResetTime(_ date: Date?) -> String {
        guard let date = date else { return "--" }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Now" }

        if interval < 3600 {
            // Less than 1 hour - show MM:SS
            let minutes = Int(interval / 60)
            let seconds = Int(interval) % 60
            return String(format: "%02d:%02d", minutes, seconds)
        } else if interval < 86400 {
            // Less than 24 hours - show Xh Xm
            let hours = Int(interval / 3600)
            let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        } else {
            // More than 24 hours - show days
            let days = Int(interval / 86400)
            let hours = Int((interval.truncatingRemainder(dividingBy: 86400)) / 3600)
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }
    }

    /// Format reset time as short string for compact view
    static func formatShortResetTime(_ date: Date?) -> String {
        guard let date = date else { return "--:--" }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "00:00" }

        if interval < 3600 {
            let minutes = Int(interval / 60)
            let seconds = Int(interval) % 60
            return String(format: "%02d:%02d", minutes, seconds)
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            let minutes = Int((interval.truncatingRemainder(dividingBy: 3600)) / 60)
            return String(format: "%02d:%02d", hours, minutes)
        } else {
            let days = Int(interval / 86400)
            return "\(days)d"
        }
    }

    // MARK: - Token Formatting

    /// Format token count for display
    static func formatTokenCount(_ tokens: Int?) -> String {
        guard let tokens = tokens, tokens > 0 else { return "0" }

        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        } else {
            return "\(tokens)"
        }
    }
}
