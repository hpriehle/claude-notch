//
//  ClaudeCompactView.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import SwiftUI
import Defaults

/// Compact view for the closed notch state showing key usage stats
struct ClaudeCompactView: View {
    @EnvironmentObject var vm: ClaudeViewModel

    @State private var displayedResetTime: String = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            // Connection indicator dot
            Circle()
                .fill(vm.usageData.isOAuthConnected ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)

            // Staleness indicator - orange dot when data is old (only show if we have data)
            if vm.usageData.hasAnyData {
                let age = Date().timeIntervalSince(vm.usageData.lastUpdated)
                if age > 300 { // > 5 minutes
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
            }

            // Show loading state if no data at all
            if !vm.usageData.hasAnyData {
                Text("--")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.gray)
            } else if vm.usageData.hasOAuthData {
                // API data available - show percentages
                let sessionPercent = vm.usageData.oauthSessionPercent
                let weeklyAllPercent = vm.usageData.oauthWeeklyAllPercent

                // Session percentage
                if Defaults[.showSessionUsage], let sessionPercent = sessionPercent {
                    Text("\(sessionPercent)%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(vm.usageData.colorForPercent(sessionPercent))

                    Divider()
                        .frame(height: 10)
                        .background(Color.gray.opacity(0.3))
                }

                // Weekly all-models percentage
                if Defaults[.showWeeklyAllUsage], let weeklyAllPercent = weeklyAllPercent {
                    Text("\(weeklyAllPercent)%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(vm.usageData.colorForPercent(weeklyAllPercent))

                    Divider()
                        .frame(height: 10)
                        .background(Color.gray.opacity(0.3))
                }

                // Reset timer (shows session reset time if available, otherwise weekly)
                let resetTime = vm.usageData.displaySessionResetTime ?? vm.usageData.displayWeeklyAllResetTime
                if resetTime != nil {
                    Text(displayedResetTime)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.gray)
                }
            } else if vm.usageData.hasCodeData {
                // Only code data - show token count
                if let weeklyTokens = vm.usageData.codeWeeklyTokens {
                    Text(ClaudeUsageData.formatTokenCount(weeklyTokens))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("this week")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.gray)
                }
            }
        }
        .padding(.horizontal, 12)
        .onAppear {
            updateResetTime()
        }
        .onReceive(timer) { _ in
            updateResetTime()
        }
    }

    private func updateResetTime() {
        let resetTime = vm.usageData.displaySessionResetTime ?? vm.usageData.displayWeeklyAllResetTime
        displayedResetTime = ClaudeUsageData.formatShortResetTime(resetTime)
    }
}

#Preview {
    ClaudeCompactView()
        .environmentObject(ClaudeViewModel())
        .frame(width: 200, height: 32)
        .background(Color.black)
}
