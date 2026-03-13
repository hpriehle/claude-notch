//
//  UsageHistoryStore.swift
//  claudeNotch
//
//  Persists hourly usage snapshots for the history chart.
//

import Foundation

// MARK: - Snapshot Model

struct UsageSnapshot: Codable, Identifiable {
    var id: String { hourKey }
    let hourKey: String      // "yyyy-MM-dd-HH" — used for dedup
    let date: Date
    let sessionPct: Int
    let weeklyAllPct: Int
    let weeklySonnetPct: Int
}

// MARK: - Metric Enum

enum HistoryMetric: String, CaseIterable {
    case session     = "Session"
    case weeklyAll   = "Weekly"
    case weeklySonnet = "Sonnet"

    func value(from snap: UsageSnapshot) -> Int {
        switch self {
        case .session:      return snap.sessionPct
        case .weeklyAll:    return snap.weeklyAllPct
        case .weeklySonnet: return snap.weeklySonnetPct
        }
    }
}

// MARK: - Store

final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private let maxSnapshots  = 168   // 7 days × 24 hours
    private let changeThreshold = 2   // % — skip write if value hasn't drifted

    private(set) var snapshots: [UsageSnapshot] = []

    private let fileURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("claudeNotch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage_history.json")
    }()

    private init() { load() }

    // MARK: - Public API

    /// Record a snapshot for the current hour. Skips if value hasn't changed enough.
    func record(_ data: ClaudeUsageData) {
        let session     = data.oauthSessionPercent     ?? data.sessionPercent     ?? -1
        let weeklyAll   = data.oauthWeeklyAllPercent   ?? data.weeklyAllPercent   ?? -1
        let weeklySonnet = data.oauthWeeklySonnetPercent ?? data.weeklySonnetPercent ?? -1
        guard session >= 0 else { return }

        let key = hourKey(for: Date())

        if let existing = snapshots.first(where: { $0.hourKey == key }) {
            let drifted = abs(existing.sessionPct     - session)      > changeThreshold
                       || abs(existing.weeklyAllPct   - weeklyAll)    > changeThreshold
                       || abs(existing.weeklySonnetPct - weeklySonnet) > changeThreshold
            guard drifted else { return }
            snapshots.removeAll { $0.hourKey == key }
        }

        snapshots.append(UsageSnapshot(
            hourKey:      key,
            date:         Date(),
            sessionPct:   session,
            weeklyAllPct: max(0, weeklyAll),
            weeklySonnetPct: max(0, weeklySonnet)
        ))

        if snapshots.count > maxSnapshots {
            snapshots = Array(snapshots.suffix(maxSnapshots))
        }
        save()
    }

    /// Returns a [dayIndex 0..6][hourIndex 0..23] grid.
    /// dayIndex 0 = 6 days ago, 6 = today.
    func grid() -> [[UsageSnapshot?]] {
        let cal = Calendar.current
        let now = Date()
        var result: [[UsageSnapshot?]] = Array(
            repeating: Array(repeating: nil as UsageSnapshot?, count: 24),
            count: 7
        )
        for dayOffset in 0..<7 {
            guard let day = cal.date(byAdding: .day, value: -(6 - dayOffset), to: now) else { continue }
            let dayComps = cal.dateComponents([.year, .month, .day], from: day)
            for hour in 0..<24 {
                var comps = dayComps; comps.hour = hour
                guard let slotDate = cal.date(from: comps) else { continue }
                let key = hourKey(for: slotDate)
                result[dayOffset][hour] = snapshots.first { $0.hourKey == key }
            }
        }
        return result
    }

    // MARK: - Private

    private func hourKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02d-%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UsageSnapshot].self, from: data)
        else { return }
        snapshots = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - Observable wrapper for SwiftUI

final class UsageHistoryStoreObservable: ObservableObject {
    static let shared = UsageHistoryStoreObservable()
    @Published private(set) var snapshots: [UsageSnapshot] = []

    private init() {
        snapshots = UsageHistoryStore.shared.snapshots
        NotificationCenter.default.addObserver(
            forName: .usageHistoryUpdated, object: nil, queue: .main
        ) { [weak self] _ in
            self?.snapshots = UsageHistoryStore.shared.snapshots
        }
    }

    func grid() -> [[UsageSnapshot?]] { UsageHistoryStore.shared.grid() }
}

extension Notification.Name {
    static let usageHistoryUpdated = Notification.Name("usageHistoryUpdated")
}
