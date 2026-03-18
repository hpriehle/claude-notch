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
    private let cellSize: CGFloat
    private let cellSpacing: CGFloat = 3
    private let rows = 7  // Days in a week

    init(dailyTokens: [DailyTokenData], weeks: Int = 13, cellSize: CGFloat = 10) {
        self.dailyTokens = dailyTokens
        self.weeks = weeks
        self.cellSize = cellSize
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
                                    isHovered: hoveredDay?.id == dayData.id,
                                    size: cellSize
                                )
                                .onHover { hovering in
                                    hoveredDay = hovering ? dayData : nil
                                }
                            } else {
                                CellView(intensity: 0, isHovered: false, size: cellSize)
                                    .opacity(0.3)
                            }
                        }
                    }
                }
            }

            // Legend and hover info — always same height to prevent grid jiggle
            HStack {
                // Legend
                HStack(spacing: 4) {
                    Text("Less")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)

                    ForEach(0..<5, id: \.self) { intensity in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorForIntensity(intensity))
                            .frame(width: 8, height: 8)
                    }

                    Text("More")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }

                // Hover info — always rendered, just hidden when not hovering
                HStack(spacing: 4) {
                    Text("·")
                        .foregroundColor(.gray)
                    Text(hoveredDay.map { formatDate($0.date) } ?? "")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white)
                    Text("•")
                        .foregroundColor(.gray)
                    Text(hoveredDay.map { formatTokens($0.tokens) } ?? "")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(hoveredDay.map { colorForIntensity($0.intensity) } ?? .clear)
                }
                .opacity(hoveredDay != nil ? 1 : 0)

                Spacer()
            }
        }
    }

    // MARK: - Cell View

    struct CellView: View {
        let intensity: Int
        let isHovered: Bool
        var size: CGFloat = 10

        var body: some View {
            RoundedRectangle(cornerRadius: 2)
                .fill(colorForIntensity(intensity))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.white.opacity(isHovered ? 0.5 : 0), lineWidth: 1)
                )
                .animation(.easeInOut(duration: 0.1), value: isHovered)
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
    case 0:  return Color.white.opacity(0.08)
    case 1:  return Color(red: 217/255, green: 119/255, blue: 87/255).opacity(0.35)
    case 2:  return Color(red: 217/255, green: 119/255, blue: 87/255).opacity(0.55)
    case 3:  return Color(red: 217/255, green: 119/255, blue: 87/255).opacity(0.75)
    default: return Color(red: 217/255, green: 119/255, blue: 87/255)
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

        // Anchor end of grid to Saturday of current week so today is always visible.
        // alignedEnd = today + daysToSaturday (0 if today is already Saturday)
        // alignedStart = alignedEnd - weeks*7 + 1, which is always a Sunday
        let todayWeekday = calendar.component(.weekday, from: today)  // 1=Sun … 7=Sat
        let daysToSaturday = (7 - todayWeekday) % 7
        guard let alignedEnd = calendar.date(byAdding: .day, value: daysToSaturday, to: today),
              let alignedStart = calendar.date(byAdding: .day, value: -(totalDays - 1), to: alignedEnd) else {
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
