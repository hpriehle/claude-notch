//
//  UsageNotificationManager.swift
//  claudeNotch
//
//  Manages macOS notifications for rate limit warnings
//

import Foundation
import UserNotifications
import Defaults
import Combine

class UsageNotificationManager: ObservableObject {
    static let shared = UsageNotificationManager()

    // MARK: - Properties

    private var notifiedSessionThresholds: Set<Int> = []
    private var notifiedWeeklyThresholds: Set<Int> = []
    private var lastSessionResetTime: Date?
    private var lastWeeklyResetTime: Date?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    private init() {
        // Always enforce the canonical thresholds (overrides any persisted user value)
        Defaults[.usageNotificationThresholds] = [90, 95, 99]
        requestNotificationPermission()
        setupUsageObserver()
    }

    // MARK: - Permission

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("[UsageNotificationManager] Notification permission granted")
            } else if let error = error {
                print("[UsageNotificationManager] Notification permission error: \(error)")
            }
        }
    }

    // MARK: - Observer

    private func setupUsageObserver() {
        NotificationCenter.default.publisher(for: .claudeUsageDataReceived)
            .compactMap { $0.userInfo?["data"] as? ClaudeUsageData }
            .sink { [weak self] usage in
                self?.checkAndNotify(usage: usage)
            }
            .store(in: &cancellables)
    }

    // MARK: - Check and Notify

    func checkAndNotify(usage: ClaudeUsageData) {
        guard Defaults[.enableUsageNotifications] else { return }

        let thresholds = Defaults[.usageNotificationThresholds]

        // Check for reset (clear notifications if reset time changed)
        checkForReset(usage: usage)

        // Use display values (prefer OAuth over web extension, same as UI)
        let sessionPercent = usage.displaySessionPercent
        let weeklyPercent = usage.displayWeeklyAllPercent

        // If OAuth is configured, wait for OAuth data before notifying —
        // prevents firing on stale web extension data while OAuth loads.
        let oauthConfigured = ClaudeOAuthUsageFetcher.shared.isConfigured
        let readyToNotify = !oauthConfigured || usage.hasOAuthData

        // Check session thresholds (only if we have trustworthy data)
        if usage.hasAnyData && readyToNotify {
            for threshold in thresholds {
                if sessionPercent >= threshold && !notifiedSessionThresholds.contains(threshold) {
                    sendSessionNotification(percent: sessionPercent, threshold: threshold, resetTime: usage.displaySessionResetTime)
                    notifiedSessionThresholds.insert(threshold)
                }
            }

            // Check weekly thresholds
            for threshold in thresholds {
                if weeklyPercent >= threshold && !notifiedWeeklyThresholds.contains(threshold) {
                    sendWeeklyNotification(percent: weeklyPercent, threshold: threshold, resetTime: usage.displayWeeklyAllResetTime)
                    notifiedWeeklyThresholds.insert(threshold)
                }
            }
        }
    }

    // MARK: - Reset Detection

    private func checkForReset(usage: ClaudeUsageData) {
        // Use display values (prefer OAuth) for reset detection
        if let sessionReset = usage.displaySessionResetTime {
            if lastSessionResetTime == nil || sessionReset != lastSessionResetTime {
                if let lastReset = lastSessionResetTime, sessionReset > lastReset {
                    notifiedSessionThresholds.removeAll()
                    print("[UsageNotificationManager] Session reset detected, clearing session notifications")
                }
                lastSessionResetTime = sessionReset
            }
        }

        if let weeklyReset = usage.displayWeeklyAllResetTime {
            if lastWeeklyResetTime == nil || weeklyReset != lastWeeklyResetTime {
                if let lastReset = lastWeeklyResetTime, weeklyReset > lastReset {
                    notifiedWeeklyThresholds.removeAll()
                    print("[UsageNotificationManager] Weekly reset detected, clearing weekly notifications")
                }
                lastWeeklyResetTime = weeklyReset
            }
        }
    }

    // MARK: - Send Notifications

    private func sendSessionNotification(percent: Int, threshold: Int, resetTime: Date?) {
        let resetString = formatResetTime(resetTime)

        let content = UNMutableNotificationContent()
        content.title = "Claude Session Warning"
        content.body = "Session usage at \(percent)%. \(resetString)"
        content.sound = .default
        content.categoryIdentifier = "USAGE_WARNING"

        // Add warning level to thread identifier for grouping
        content.threadIdentifier = "claude-session-\(warningLevel(for: threshold))"

        sendNotification(content: content, identifier: "session-\(threshold)")
    }

    private func sendWeeklyNotification(percent: Int, threshold: Int, resetTime: Date?) {
        let resetString = formatResetTime(resetTime)

        let content = UNMutableNotificationContent()
        content.title = "Claude Weekly Warning"
        content.body = "Weekly usage at \(percent)%. \(resetString)"
        content.sound = threshold >= 90 ? .defaultCritical : .default
        content.categoryIdentifier = "USAGE_WARNING"

        content.threadIdentifier = "claude-weekly-\(warningLevel(for: threshold))"

        sendNotification(content: content, identifier: "weekly-\(threshold)")
    }

    private func sendNotification(content: UNMutableNotificationContent, identifier: String) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[UsageNotificationManager] Failed to send notification: \(error)")
            } else {
                print("[UsageNotificationManager] Sent notification: \(identifier)")
            }
        }
    }

    // MARK: - Helpers

    private func formatResetTime(_ date: Date?) -> String {
        guard let date = date else { return "" }

        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Resetting soon" }

        if interval < 3600 {
            let minutes = Int(interval / 60)
            return "Resets in \(minutes)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "Resets in \(hours)h"
        } else {
            let days = Int(interval / 86400)
            return "Resets in \(days)d"
        }
    }

    private func warningLevel(for threshold: Int) -> String {
        switch threshold {
        case 0..<70: return "info"
        case 70..<85: return "caution"
        case 85..<95: return "warning"
        default: return "critical"
        }
    }

    // MARK: - Manual Reset

    func resetAllNotifications() {
        notifiedSessionThresholds.removeAll()
        notifiedWeeklyThresholds.removeAll()
        print("[UsageNotificationManager] All notifications reset manually")
    }
}
