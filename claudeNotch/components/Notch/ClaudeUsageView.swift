//
//  ClaudeUsageView.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import SwiftUI
import Defaults

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
                ConnectionIndicator(isConnected: vm.isExtensionConnected)
            }
            .padding(.bottom, 4)

            // Session Usage
            if Defaults[.showSessionUsage] {
                UsageBarView(
                    label: "Session",
                    percent: vm.usageData.sessionPercent,
                    resetTime: vm.usageData.sessionResetTime,
                    color: vm.usageData.colorForPercent(vm.usageData.sessionPercent)
                )
            }

            // Weekly All Models Usage
            if Defaults[.showWeeklyAllUsage] {
                UsageBarView(
                    label: "Weekly (All Models)",
                    percent: vm.usageData.weeklyAllPercent,
                    resetTime: vm.usageData.weeklyAllResetTime,
                    color: vm.usageData.colorForPercent(vm.usageData.weeklyAllPercent)
                )
            }

            // Weekly Sonnet Usage
            if Defaults[.showWeeklySonnetUsage] {
                UsageBarView(
                    label: "Weekly (Sonnet)",
                    percent: vm.usageData.weeklySonnetPercent,
                    resetTime: vm.usageData.weeklySonnetResetTime,
                    color: vm.usageData.colorForPercent(vm.usageData.weeklySonnetPercent)
                )
            }

            // Account type footer
            HStack {
                Text(vm.usageData.accountType)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.gray)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Individual usage bar with label, percentage, and reset time
struct UsageBarView: View {
    let label: String
    let percent: Int
    let resetTime: Date
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
                Text("Resets in \(displayedResetTime)")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.gray.opacity(0.8))
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

/// Connection status indicator
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
