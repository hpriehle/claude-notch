//
//  UsageHistoryView.swift
//  claudeNotch
//
//  Swipe page 2: Activity & Stats
//  Shows lifetime stats, daily token-activity grid (13 weeks), and session depth breakdown.
//

import SwiftUI

struct UsageHistoryView: View {
    @EnvironmentObject var vm: ClaudeViewModel

    @State private var contributionData: [DailyTokenData] = []
    @State private var gridTokenData: [StatsCache.DailyModelTokens] = []
    @State private var totalSessions: Int = 0
    @State private var totalMessages: Int = 0
    @State private var totalTokens: Int = 0
    @State private var peakHour: String = "--"
    @State private var sessionBreakdown: SessionBreakdown? = nil
    @State private var gridWidth: CGFloat = 0
    @State private var lastComputedDate: String = ""
    @State private var jsonlDailyTokens: [String: Int] = [:]

    private let parser = JSONLParser()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            statsRow
            gridSection
            if let breakdown = sessionBreakdown, breakdown.total > 0 {
                sessionDepthSection(breakdown)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .onAppear { loadData() }
        .onReceive(NotificationCenter.default.publisher(for: .claudeUsageDataReceived)) { _ in
            loadData()
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("Activity")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
        }
    }

    // MARK: - Stats Row

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        return f.string(from: Date())
    }

    private var statsRow: some View {
        HStack(spacing: 0) {
            activityStatItem(label: "Sessions", value: formatNumber(totalSessions))
            Spacer()
            activityStatItem(label: "Messages", value: formatNumber(totalMessages))
            Spacer()
            activityStatItem(label: "Today", value: formatTokens(jsonlDailyTokens[todayKey] ?? 0))
            Spacer()
            activityStatItem(label: "Peak Hour", value: peakHour)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private func activityStatItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    // MARK: - Contribution Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Token Activity")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                Spacer()
                if !lastComputedDate.isEmpty {
                    Text("updated \(lastComputedDate)")
                        .font(.system(size: 9))
                        .foregroundColor(.gray.opacity(0.6))
                }
            }

            if contributionData.isEmpty {
                HStack {
                    Spacer()
                    Text("No activity data yet")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                    Spacer()
                }
                .frame(height: 60)
            } else {
                // Measure available width via .background(GeometryReader) — avoids width=0 on first pass
                Color.clear
                    .frame(height: 0)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { gridWidth = geo.size.width }
                            .onChange(of: geo.size.width) { _, newWidth in gridWidth = newWidth }
                    })

                let weeksToShow = gridWidth > 0
                    ? min(52, max(13, Int((gridWidth + 3) / 13)))
                    : 13
                let cellSize: CGFloat = gridWidth > 0
                    ? (gridWidth - CGFloat(weeksToShow - 1) * 3) / CGFloat(weeksToShow)
                    : 10
                let processed = ContributionGridView.processTokenData(from: mergedDailyTokens(), weeks: weeksToShow)
                ContributionGridView(dailyTokens: processed, weeks: weeksToShow, cellSize: cellSize)
                    .frame(height: 99)
            }
        }
    }

    // MARK: - Session Depth

    private func sessionDepthSection(_ breakdown: SessionBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session Depth")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.gray)

            depthRow(label: "Quick", sublabel: "<5 msgs", count: breakdown.quickCount, total: breakdown.total, color: Color(red: 16/255, green: 185/255, blue: 129/255))
            depthRow(label: "Focused", sublabel: "5–20", count: breakdown.focusedCount, total: breakdown.total, color: Color(red: 245/255, green: 158/255, blue: 11/255))
            depthRow(label: "Deep", sublabel: "20+", count: breakdown.deepCount, total: breakdown.total, color: Color(red: 249/255, green: 115/255, blue: 22/255))
        }
    }

    private func depthRow(label: String, sublabel: String, count: Int, total: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            // Labels
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .frame(width: 46, alignment: .leading)
                Text(sublabel)
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .frame(width: 36, alignment: .leading)
            }

            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.75))
                        .frame(width: total > 0 ? geo.size.width * CGFloat(count) / CGFloat(total) : 0)
                }
            }
            .frame(height: 6)

            // Count
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.gray)
                .frame(width: 32, alignment: .trailing)
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        guard let stats = parser.parseStatsCache() else { return }

        gridTokenData = stats.dailyModelTokens ?? []
        contributionData = ContributionGridView.processTokenData(from: stats.dailyModelTokens, weeks: 13)
        totalSessions = stats.totalSessions ?? 0
        totalMessages = stats.totalMessages ?? 0
        totalTokens = computeTotalTokens(from: stats.modelUsage)
        peakHour = computePeakHour(from: stats.hourCounts)
        lastComputedDate = formatLastComputed(stats.lastComputedDate)

        // Read from disk cache — instant. The cache is built/updated by ClaudeUsageService.start().
        jsonlDailyTokens = DailyTokenCache.shared.load()
    }

    // MARK: - Helpers

    private func mergedDailyTokens() -> [StatsCache.DailyModelTokens] {
        var merged: [String: [String: Int]] = [:]
        // Stats-cache as baseline for dates not in JSONL cache
        for entry in gridTokenData {
            if let m = entry.tokensByModel { merged[entry.date] = m }
        }
        // JSONL output-token data wins for any date it has (consistent scale across all dates)
        for (date, tokens) in jsonlDailyTokens {
            merged[date] = ["jsonl-output": tokens]
        }
        return merged.map { StatsCache.DailyModelTokens(date: $0.key, tokensByModel: $0.value) }
    }

    private func computeTotalTokens(from modelUsage: [String: StatsCache.ModelStats]?) -> Int {
        guard let usage = modelUsage else { return 0 }
        return usage.values.reduce(0) { acc, m in
            acc + (m.inputTokens ?? 0) + (m.outputTokens ?? 0)
                + (m.cacheReadInputTokens ?? 0) + (m.cacheCreationInputTokens ?? 0)
        }
    }

    private func computePeakHour(from hourCounts: [String: Int]?) -> String {
        guard let counts = hourCounts, !counts.isEmpty,
              let maxKey = counts.max(by: { $0.value < $1.value })?.key,
              let hour = Int(maxKey) else { return "--" }
        // hourCounts keys are UTC hours (JSONL timestamps end in Z).
        // Build the date in UTC, then let DateFormatter display in local time.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let date = utcCal.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        let fmt = DateFormatter()
        fmt.dateFormat = "h a"
        // timeZone defaults to TimeZone.current — auto-converts UTC → local
        return fmt.string(from: date).lowercased()
    }

    private func formatNumber(_ num: Int) -> String {
        if num >= 1_000_000 { return String(format: "%.1fM", Double(num) / 1_000_000) }
        if num >= 1_000 { return String(format: "%.1fK", Double(num) / 1_000) }
        return "\(num)"
    }

    private func formatLastComputed(_ raw: String?) -> String {
        guard let raw = raw else { return "" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let date = fmt.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date = date else { return "" }
        let out = DateFormatter()
        out.dateFormat = "MMM d"
        return out.string(from: date)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 { return String(format: "%.1fB", Double(tokens) / 1_000_000_000) }
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return String(format: "%.0fK", Double(tokens) / 1_000) }
        return "\(tokens)"
    }
}

#Preview {
    UsageHistoryView()
        .environmentObject(ClaudeViewModel())
        .frame(width: 640, height: 300)
        .background(Color.black)
}
