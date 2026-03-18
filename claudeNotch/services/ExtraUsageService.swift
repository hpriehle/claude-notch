//
//  ExtraUsageService.swift
//  claudeNotch
//
//  Tracks whether Claude's extra usage promotion is currently active.
//  Promotion: March 13–28, 2026. Doubles 5-hour limits during off-peak hours.
//  Peak hours (extra usage INACTIVE): weekdays 8 AM – 2 PM Eastern Time.
//  Off-peak (extra usage ACTIVE): weekdays outside 8–2 ET + all weekend hours.
//

import Foundation
import Combine
import UserNotifications

class ExtraUsageService: ObservableObject {
    static let shared = ExtraUsageService()

    // MARK: - Debug

    /// Force extra usage active for development/testing. Set to true to bypass date/time checks.
    private static let forceActive = false

    // MARK: - Published State

    @Published private(set) var isExtraUsageActive: Bool = false
    @Published private(set) var isPromotionPeriod: Bool = false
    /// When the current extra usage window ends (next peak start, or promotion end)
    @Published private(set) var extraUsageEndsAt: Date?

    // MARK: - Private

    private static let easternTZ = TimeZone(identifier: "America/New_York")!
    private static let pacificTZ = TimeZone(identifier: "America/Los_Angeles")!

    /// Promotion window in Pacific Time
    private static let promotionStart: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 13
        comps.hour = 0; comps.minute = 0; comps.second = 0
        comps.timeZone = pacificTZ
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()

    private static let promotionEnd: Date = {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 28
        comps.hour = 23; comps.minute = 59; comps.second = 59
        comps.timeZone = pacificTZ
        return Calendar(identifier: .gregorian).date(from: comps)!
    }()

    private var timer: Timer?
    private var wasActive: Bool = false
    private var isFirstEvaluation: Bool = true

    // MARK: - Init

    private init() {
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluate()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Evaluation

    private func evaluate() {
        // Debug override: always show as active
        if Self.forceActive {
            isPromotionPeriod = true
            isExtraUsageActive = true
            // In debug, show a fake countdown 2 hours from now
            extraUsageEndsAt = Date().addingTimeInterval(2 * 3600)
            if !isFirstEvaluation && !wasActive {
                sendExtraUsageStartedNotification()
            }
            wasActive = true
            isFirstEvaluation = false
            return
        }

        let now = Date()

        // 1. Check promotion window
        guard now >= Self.promotionStart && now <= Self.promotionEnd else {
            let wasInPeriod = isPromotionPeriod
            isPromotionPeriod = false

            if isExtraUsageActive {
                isExtraUsageActive = false
                if !isFirstEvaluation && wasActive {
                    sendExtraUsageEndedNotification()
                }
            }

            wasActive = false
            isFirstEvaluation = false
            return
        }

        isPromotionPeriod = true

        // 2. Determine if currently off-peak in Eastern Time
        var etCal = Calendar(identifier: .gregorian)
        etCal.timeZone = Self.easternTZ

        let weekday = etCal.component(.weekday, from: now) // 1=Sun, 7=Sat
        let isWeekend = weekday == 1 || weekday == 7

        let hour = etCal.component(.hour, from: now)
        let isPeakHour = hour >= 8 && hour < 14

        let active = isWeekend || !isPeakHour
        isExtraUsageActive = active

        // 3. Compute when extra usage ends
        if active {
            extraUsageEndsAt = Self.computeNextPeakStart(from: now)
        } else {
            extraUsageEndsAt = nil
        }

        // 4. Send notifications on transitions (skip first evaluation)
        if !isFirstEvaluation {
            if !wasActive && active {
                sendExtraUsageStartedNotification()
            } else if wasActive && !active {
                sendExtraUsageEndedNotification()
            }
        }

        wasActive = active
        isFirstEvaluation = false
    }

    // MARK: - Next Peak Calculation

    /// Computes the next weekday 8 AM ET from the given date.
    /// If currently off-peak on a weekday evening, next peak is tomorrow 8 AM ET (if tomorrow is a weekday).
    /// If currently on a weekend, next peak is Monday 8 AM ET.
    private static func computeNextPeakStart(from date: Date) -> Date? {
        var etCal = Calendar(identifier: .gregorian)
        etCal.timeZone = easternTZ

        let weekday = etCal.component(.weekday, from: date) // 1=Sun, 7=Sat
        let hour = etCal.component(.hour, from: date)

        var targetDate = date

        if weekday >= 2 && weekday <= 6 {
            // Weekday
            if hour < 8 {
                // Before peak today — peak starts today at 8 AM ET
                // targetDate stays as today
            } else {
                // After peak (>=14) or during peak — next peak is next weekday 8 AM
                targetDate = etCal.date(byAdding: .day, value: 1, to: date)!
            }
        }

        // Advance past weekends
        var wd = etCal.component(.weekday, from: targetDate)
        while wd == 1 || wd == 7 {
            targetDate = etCal.date(byAdding: .day, value: 1, to: targetDate)!
            wd = etCal.component(.weekday, from: targetDate)
        }

        // Set to 8 AM ET on that day
        var comps = etCal.dateComponents([.year, .month, .day], from: targetDate)
        comps.hour = 8
        comps.minute = 0
        comps.second = 0
        comps.timeZone = easternTZ

        guard let peakStart = etCal.date(from: comps) else { return nil }

        // Cap at promotion end
        return min(peakStart, promotionEnd)
    }

    // MARK: - Notifications

    private func sendExtraUsageStartedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Extra Usage Active"
        content.body = "Claude's off-peak 2x usage bonus is now active."
        content.sound = .default
        content.threadIdentifier = "claude-extra-usage"

        let request = UNNotificationRequest(
            identifier: "extra-usage-started-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[ExtraUsageService] Failed to send started notification: \(error)")
            }
        }
    }

    private func sendExtraUsageEndedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Extra Usage Ended"
        content.body = "Peak hours have started (8 AM–2 PM ET). Standard usage limits apply."
        content.sound = .default
        content.threadIdentifier = "claude-extra-usage"

        let request = UNNotificationRequest(
            identifier: "extra-usage-ended-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[ExtraUsageService] Failed to send ended notification: \(error)")
            }
        }
    }
}
