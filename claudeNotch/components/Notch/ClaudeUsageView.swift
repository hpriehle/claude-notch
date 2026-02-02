//
//  ClaudeUsageView.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import SwiftUI
import Defaults
import AppKit

/// Expanded view showing full Claude usage statistics
struct ClaudeUsageView: View {
    @EnvironmentObject var vm: ClaudeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text("Claude Usage")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()

                // Refresh button
                Button(action: {
                    WebSocketServer.shared.requestRefresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .help("Refresh usage data")

                ConnectionStatusView(
                    isConnected: vm.isExtensionConnected,
                    hasWebData: vm.usageData.hasWebData,
                    lastUpdated: vm.usageData.lastUpdated
                )
            }
            .padding(.bottom, 4)

            // Show empty state if no data
            if !vm.usageData.hasAnyData {
                EmptyUsageView()
            } else {
                // Session Usage
                if Defaults[.showSessionUsage], let sessionPercent = vm.usageData.sessionPercent {
                    UsageBarView(
                        label: "Session",
                        percent: sessionPercent,
                        resetTime: vm.usageData.sessionResetTime,
                        color: vm.usageData.colorForPercent(sessionPercent)
                    )
                }

                // Weekly All Models Usage
                if Defaults[.showWeeklyAllUsage], let weeklyAllPercent = vm.usageData.weeklyAllPercent {
                    UsageBarView(
                        label: "Weekly (All Models)",
                        percent: weeklyAllPercent,
                        resetTime: vm.usageData.weeklyAllResetTime,
                        color: vm.usageData.colorForPercent(weeklyAllPercent)
                    )
                }

                // Weekly Sonnet Usage
                if Defaults[.showWeeklySonnetUsage], let weeklySonnetPercent = vm.usageData.weeklySonnetPercent {
                    UsageBarView(
                        label: "Weekly (Sonnet)",
                        percent: weeklySonnetPercent,
                        resetTime: vm.usageData.weeklySonnetResetTime,
                        color: vm.usageData.colorForPercent(weeklySonnetPercent)
                    )
                }

                // Account type footer
                if let accountType = vm.usageData.accountType {
                    HStack {
                        Text(accountType)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.gray)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(4)
                        Spacer()
                    }
                }

                // Show code stats when available (fallback when no web data)
                if vm.usageData.hasCodeData {
                    CodeUsageView(usageData: vm.usageData)
                }
            }
        }
        .padding(.horizontal, 28)  // Avoid corner clipping (corner radius is 24pt)
        .padding(.top, 16)
        .padding(.bottom, 28)      // Extra bottom padding for rounded corners
    }
}

/// Empty state view when no usage data is available
struct EmptyUsageView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 24))
                .foregroundColor(.gray.opacity(0.5))
            Text("No usage data yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.gray)
            Text("Use Claude Code or connect the browser extension")
                .font(.system(size: 10))
                .foregroundColor(.gray.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

/// Code usage stats view
struct CodeUsageView: View {
    let usageData: ClaudeUsageData

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.gray)

            HStack(spacing: 16) {
                if let weeklyTokens = usageData.codeWeeklyTokens {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("This Week")
                            .font(.system(size: 9))
                            .foregroundColor(.gray.opacity(0.7))
                        Text(ClaudeUsageData.formatTokenCount(weeklyTokens))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }

                if let todayTokens = usageData.codeTodayTokens, todayTokens > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today")
                            .font(.system(size: 9))
                            .foregroundColor(.gray.opacity(0.7))
                        Text(ClaudeUsageData.formatTokenCount(todayTokens))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Individual usage bar with label, percentage, and reset time
struct UsageBarView: View {
    let label: String
    let percent: Int
    let resetTime: Date?
    let color: Color

    @State private var displayedResetTime: String = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Label row
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.gray)
                Spacer()
                if resetTime != nil {
                    Text("Resets in \(displayedResetTime)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.gray.opacity(0.8))
                }
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))

                    // Progress
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percent) / 100)
                        .animation(.easeInOut(duration: 0.3), value: percent)
                }
            }
            .frame(height: 8)

            // Percentage
            Text("\(percent)%")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
        .onAppear {
            displayedResetTime = ClaudeUsageData.formatResetTime(resetTime)
        }
        .onReceive(timer) { _ in
            displayedResetTime = ClaudeUsageData.formatResetTime(resetTime)
        }
    }
}

/// Connection status view with multiple states
struct ConnectionStatusView: View {
    let isConnected: Bool
    let hasWebData: Bool
    let lastUpdated: Date?

    var body: some View {
        if isConnected {
            // Connected and receiving live data
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Live")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
        } else if hasWebData {
            // Has cached web data but not currently connected
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                if let lastUpdated {
                    Text(formatRelativeTime(lastUpdated))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.orange)
                } else {
                    Text("Cached")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.orange)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
        } else {
            // No web data - show "Open Claude" button
            Button(action: {
                if let url = URL(string: "https://claude.ai/settings/usage") {
                    NSWorkspace.shared.open(url)
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                    Text("Open Claude")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    private func formatRelativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

/// Legacy connection indicator (kept for compatibility)
struct ConnectionIndicator: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray)
                .frame(width: 6, height: 6)
            Text(isConnected ? "Live" : "Offline")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(isConnected ? .green : .gray)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

#Preview {
    ClaudeUsageView()
        .environmentObject(ClaudeViewModel())
        .frame(width: 400, height: 200)
        .background(Color.black)
}
