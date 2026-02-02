//
//  ContributionGridView.swift
//  claudeNotch
//
//  GitHub-style contribution grid showing token usage over time
//

import SwiftUI

// MARK: - Data Model

struct DailyTokenData: Identifiable {
    let id = UUID()
    let date: Date
    let tokens: Int
    let intensity: Int  // 0-4 for color levels

    static func empty(for date: Date) -> DailyTokenData {
        DailyTokenData(date: date, tokens: 0, intensity: 0)
    }
}

// MARK: - Contribution Grid View

struct ContributionGridView: View {
    let dailyTokens: [DailyTokenData]
    let weeks: Int

    @State private var hoveredDay: DailyTokenData?

    // Grid dimensions
    private let cellSize: CGFloat = 10
    private let cellSpacing: CGFloat = 3
    private let rows = 7  // Days in a week

    init(dailyTokens: [DailyTokenData], weeks: Int = 13) {
        self.dailyTokens = dailyTokens
        self.weeks = weeks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Grid
            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(0..<weeks, id: \.self) { weekIndex in
                    VStack(spacing: cellSpacing) {
                        ForEach(0..<rows, id: \.self) { dayIndex in
                            let dataIndex = weekIndex * 7 + dayIndex
                            if dataIndex < dailyTokens.count {
                                let dayData = dailyTokens[dataIndex]
                                CellView(
                                    intensity: dayData.intensity,
                                    isHovered: hoveredDay?.id == dayData.id
                                )
                                .onHover { hovering in
                                    hoveredDay = hovering ? dayData : nil
                                }
                            } else {
                                CellView(intensity: 0, isHovered: false)
                                    .opacity(0.3)
                            }
                        }
                    }
                }
            }

            // Legend and hover info
            HStack {
                // Legend
                HStack(spacing: 4) {
                    Text("Less")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)

                    ForEach(0..<5, id: \.self) { intensity in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorForIntensity(intensity))
                            .frame(width: 10, height: 10)
                    }

                    Text("More")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }

                Spacer()

                // Hover info or default
                if let day = hoveredDay {
                    HStack(spacing: 4) {
                        Text(formatDate(day.date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                        Text("•")
                            .foregroundColor(.gray)
                        Text(formatTokens(day.tokens))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(colorForIntensity(day.intensity))
                    }
                }
            }
        }
    }

    // MARK: - Cell View

    struct CellView: View {
        let intensity: Int
        let isHovered: Bool

        var body: some View {
            RoundedRectangle(cornerRadius: 2)
                .fill(colorForIntensity(intensity))
                .frame(width: 10, height: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(isHovered ? 0.5 : 0), lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.2 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        } else if tokens >= 1_000 {
            return String(format: "%.1fK", Double(tokens) / 1_000)
        } else {
            return "\(tokens)"
        }
    }
}

// MARK: - Color Helper (Module Level)

func colorForIntensity(_ intensity: Int) -> Color {
    switch intensity {
    case 0:
        return Color.white.opacity(0.1)
    case 1:
        return Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.4)  // Light green
    case 2:
        return Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.6)  // Medium green
    case 3:
        return Color(red: 16/255, green: 185/255, blue: 129/255).opacity(0.8)  // Bright green
    case 4:
        return Color(red: 16/255, green: 185/255, blue: 129/255)               // Full green
    default:
        return Color.white.opacity(0.1)
    }
}

// MARK: - Data Processing

extension ContributionGridView {
    /// Create contribution grid data from daily model tokens
    static func processTokenData(from dailyModelTokens: [StatsCache.DailyModelTokens]?, weeks: Int = 13) -> [DailyTokenData] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let totalDays = weeks * 7

        // Create date-to-tokens mapping
        var tokensByDate: [String: Int] = [:]

        if let dailyTokens = dailyModelTokens {
            for daily in dailyTokens {
                if let tokensByModel = daily.tokensByModel {
                    let total = tokensByModel.values.reduce(0, +)
                    tokensByDate[daily.date] = total
                }
            }
        }

        // Get all token values for percentile calculation
        let allTokenValues = tokensByDate.values.filter { $0 > 0 }.sorted()

        // Calculate percentile thresholds
        let p25 = percentile(allTokenValues, 0.25)
        let p50 = percentile(allTokenValues, 0.50)
        let p75 = percentile(allTokenValues, 0.75)

        // Generate data for each day (oldest to newest, week by week)
        var result: [DailyTokenData] = []
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        // Calculate start date (totalDays - 1 days ago, aligned to start of week)
        guard let startDate = calendar.date(byAdding: .day, value: -(totalDays - 1), to: today) else {
            return []
        }

        // Adjust to start of week (Sunday)
        let weekday = calendar.component(.weekday, from: startDate)
        guard let alignedStart = calendar.date(byAdding: .day, value: -(weekday - 1), to: startDate) else {
            return []
        }

        for dayOffset in 0..<totalDays {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: alignedStart) else {
                continue
            }

            let dateString = dateFormatter.string(from: date)
            let tokens = tokensByDate[dateString] ?? 0
            let intensity = calculateIntensity(tokens: tokens, p25: p25, p50: p50, p75: p75)

            result.append(DailyTokenData(date: date, tokens: tokens, intensity: intensity))
        }

        return result
    }

    private static func percentile(_ sortedValues: [Int], _ p: Double) -> Int {
        guard !sortedValues.isEmpty else { return 0 }
        let index = Int(Double(sortedValues.count - 1) * p)
        return sortedValues[index]
    }

    private static func calculateIntensity(tokens: Int, p25: Int, p50: Int, p75: Int) -> Int {
        if tokens == 0 { return 0 }
        if tokens <= p25 { return 1 }
        if tokens <= p50 { return 2 }
        if tokens <= p75 { return 3 }
        return 4
    }

    /// Calculate current streak (consecutive days with activity)
    static func calculateStreak(from dailyTokens: [DailyTokenData]) -> Int {
        var streak = 0
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        // Sort by date descending (most recent first)
        let sorted = dailyTokens.sorted { $0.date > $1.date }

        for (index, day) in sorted.enumerated() {
            let dayStart = calendar.startOfDay(for: day.date)

            // Expected date for this position in streak
            guard let expectedDate = calendar.date(byAdding: .day, value: -index, to: today) else {
                break
            }

            // Check if dates match and has activity
            if dayStart == expectedDate && day.tokens > 0 {
                streak += 1
            } else if dayStart == expectedDate && day.tokens == 0 {
                // Today with no activity - streak could still be ongoing from yesterday
                if index == 0 {
                    continue
                } else {
                    break
                }
            } else {
                break
            }
        }

        return streak
    }
}

// MARK: - Preview

#Preview {
    // Sample data for preview
    let sampleData: [DailyTokenData] = (0..<91).map { dayOffset in
        let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
        let tokens = Int.random(in: 0...100000)
        let intensity = tokens == 0 ? 0 : min(4, tokens / 25000 + 1)
        return DailyTokenData(date: date, tokens: tokens, intensity: intensity)
    }.reversed()

    return ContributionGridView(dailyTokens: Array(sampleData), weeks: 13)
        .padding()
        .background(Color.black)
}
