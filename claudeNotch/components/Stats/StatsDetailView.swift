//
//  StatsDetailView.swift
//  claudeNotch
//
//  Second panel in the swipeable stats view with contribution grid and rate limit intelligence
//

import SwiftUI
import Defaults

struct StatsDetailView: View {
    @EnvironmentObject var vm: ClaudeViewModel
    @ObservedObject var usageService = ClaudeUsageService.shared

    @State private var contributionData: [DailyTokenData] = []
    @State private var streak: Int = 0
    @State private var totalSessions: Int = 0
    @State private var totalMessages: Int = 0

    private let parser = JSONLParser()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text("Stats")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()

                // Streak badge
                if streak > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                        Text("\(streak) day streak")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.orange)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(8)
                }
            }
            .padding(.bottom, 4)

            // Contribution Grid Section
            VStack(alignment: .leading, spacing: 6) {
                Text("Token Activity")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)

                if contributionData.isEmpty {
                    // Empty state
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 20))
                                .foregroundColor(.gray.opacity(0.5))
                            Text("No activity data yet")
                                .font(.system(size: 10))
                                .foregroundColor(.gray)
                        }
                        Spacer()
                    }
                    .frame(height: 80)
                } else {
                    ContributionGridView(dailyTokens: contributionData, weeks: 13)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Rate Limit Forecast Section
            VStack(alignment: .leading, spacing: 8) {
                Text("Rate Limit Forecast")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)

                if vm.usageData.hasOAuthData {
                    // Weekly forecast
                    let weeklyPercent = vm.usageData.oauthWeeklyAllPercent
                    if let weeklyPercent = weeklyPercent {
                        RateLimitRow(
                            label: "Weekly",
                            percent: weeklyPercent,
                            resetTime: vm.usageData.displayWeeklyAllResetTime,
                            prediction: calculatePrediction(percent: weeklyPercent)
                        )
                    }

                    // Session forecast
                    let sessionPercent = vm.usageData.oauthSessionPercent
                    if let sessionPercent = sessionPercent {
                        RateLimitRow(
                            label: "Session",
                            percent: sessionPercent,
                            resetTime: vm.usageData.displaySessionResetTime,
                            prediction: nil  // Session is short-term, no velocity prediction
                        )
                    }
                } else {
                    // No API or web data - show prompt
                    HStack {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                        Text("Connect Claude Code for rate limit data")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()
                .background(Color.white.opacity(0.1))

            // Quick Stats Section
            HStack(spacing: 20) {
                StatItem(label: "Sessions", value: formatNumber(totalSessions))
                StatItem(label: "Messages", value: formatNumber(totalMessages))

                if let weeklyTokens = vm.usageData.codeWeeklyTokens {
                    StatItem(label: "This Week", value: ClaudeUsageData.formatTokenCount(weeklyTokens))
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 28)
        .onAppear {
            loadContributionData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .claudeUsageDataReceived)) { _ in
            loadContributionData()
        }
    }

    // MARK: - Data Loading

    private func loadContributionData() {
        guard let statsCache = parser.parseStatsCache() else {
            contributionData = []
            return
        }

        // Process contribution grid data
        contributionData = ContributionGridView.processTokenData(
            from: statsCache.dailyModelTokens,
            weeks: 13
        )

        // Calculate streak
        streak = ContributionGridView.calculateStreak(from: contributionData)

        // Load totals
        totalSessions = statsCache.totalSessions ?? 0
        totalMessages = statsCache.totalMessages ?? 0
    }

    // MARK: - Prediction Calculation

    private func calculatePrediction(percent: Int) -> String? {
        guard percent > 0 && percent < 100 else { return nil }

        // Simple heuristic: if at X%, estimate time to 100%
        // This is rough - real velocity would require tracking usage over time
        let remaining = 100 - percent
        let estimatedHoursPerPercent = 0.5  // Rough estimate

        let hoursRemaining = Double(remaining) * estimatedHoursPerPercent

        if hoursRemaining < 1 {
            return "~\(Int(hoursRemaining * 60))m left"
        } else if hoursRemaining < 24 {
            return "~\(Int(hoursRemaining))h left"
        } else {
            let days = Int(hoursRemaining / 24)
            return "~\(days)d left"
        }
    }

    private func formatNumber(_ num: Int) -> String {
        if num >= 1000 {
            return String(format: "%.1fK", Double(num) / 1000)
        }
        return "\(num)"
    }
}

// MARK: - Rate Limit Row

struct RateLimitRow: View {
    let label: String
    let percent: Int
    let resetTime: Date?
    let prediction: String?

    @State private var displayedResetTime: String = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                // Prediction or reset time
                if let pred = prediction {
                    Text(pred)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(warningColor)
                } else if resetTime != nil {
                    Text("resets \(displayedResetTime)")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
            }

            // Progress bar with percentage
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.1))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(progressColor)
                            .frame(width: geometry.size.width * CGFloat(percent) / 100)
                    }
                }
                .frame(height: 6)

                Text("\(percent)%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(progressColor)
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .onAppear {
            displayedResetTime = ClaudeUsageData.formatShortResetTime(resetTime)
        }
        .onReceive(timer) { _ in
            displayedResetTime = ClaudeUsageData.formatShortResetTime(resetTime)
        }
    }

    private var progressColor: Color {
        switch percent {
        case 0..<50:
            return Color(red: 16/255, green: 185/255, blue: 129/255)  // Green
        case 50..<70:
            return Color(red: 245/255, green: 158/255, blue: 11/255)  // Yellow
        case 70..<85:
            return Color(red: 249/255, green: 115/255, blue: 22/255)  // Orange
        default:
            return Color(red: 239/255, green: 68/255, blue: 68/255)   // Red
        }
    }

    private var warningColor: Color {
        switch percent {
        case 0..<70:
            return .gray
        case 70..<85:
            return Color(red: 249/255, green: 115/255, blue: 22/255)  // Orange
        default:
            return Color(red: 239/255, green: 68/255, blue: 68/255)   // Red
        }
    }
}

// MARK: - Stat Item

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Preview

#Preview {
    StatsDetailView()
        .environmentObject(ClaudeViewModel())
        .frame(width: 400, height: 280)
        .background(Color.black)
}
