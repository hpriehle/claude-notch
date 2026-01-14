//
//  ClaudeUsageData.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import SwiftUI
import Foundation

struct ClaudeUsageData: Codable, Equatable {
    var sessionPercent: Int
    var weeklyAllPercent: Int
    var weeklySonnetPercent: Int
    var sessionResetTime: Date
    var weeklyAllResetTime: Date
    var weeklySonnetResetTime: Date
    var accountType: String
    var isConnected: Bool
    var lastUpdated: Date

    // Static test data for Phase 1 MVP
    static var testData: ClaudeUsageData {
        let now = Date()
        let calendar = Calendar.current

        // Session resets in ~5 hours
        let sessionReset = now.addingTimeInterval(5 * 3600)

        // Weekly all-models resets next Tuesday at 9 AM
        let weeklyAllReset = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 9, minute: 0, weekday: 3),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(7 * 24 * 3600)

        // Weekly Sonnet resets next Tuesday at 11 AM
        let weeklySonnetReset = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 11, minute: 0, weekday: 3),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(7 * 24 * 3600)

        return ClaudeUsageData(
            sessionPercent: 0,
            weeklyAllPercent: 22,
            weeklySonnetPercent: 0,
            sessionResetTime: sessionReset,
            weeklyAllResetTime: weeklyAllReset,
            weeklySonnetResetTime: weeklySonnetReset,
            accountType: "Pro",
            isConnected: false,
            lastUpdated: now
        )
    }

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

    /// Format reset time as human-readable string
    static func formatResetTime(_ date: Date) -> String {
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
    static func formatShortResetTime(_ date: Date) -> String {
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
}
