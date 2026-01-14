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
                .fill(vm.isExtensionConnected ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 6, height: 6)

            // Session percentage
            if Defaults[.showSessionUsage] {
                Text("\(vm.usageData.sessionPercent)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(vm.usageData.colorForPercent(vm.usageData.sessionPercent))

                Divider()
                    .frame(height: 10)
                    .background(Color.gray.opacity(0.3))
            }

            // Weekly all-models percentage
            if Defaults[.showWeeklyAllUsage] {
                Text("\(vm.usageData.weeklyAllPercent)%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(vm.usageData.colorForPercent(vm.usageData.weeklyAllPercent))

                Divider()
                    .frame(height: 10)
                    .background(Color.gray.opacity(0.3))
            }

            // Reset timer (shows session reset time)
            Text(displayedResetTime)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)
        }
        .padding(.horizontal, 12)
        .onAppear {
            displayedResetTime = ClaudeUsageData.formatShortResetTime(vm.usageData.sessionResetTime)
        }
        .onReceive(timer) { _ in
            displayedResetTime = ClaudeUsageData.formatShortResetTime(vm.usageData.sessionResetTime)
        }
    }
}

#Preview {
    ClaudeCompactView()
        .environmentObject(ClaudeViewModel())
        .frame(width: 200, height: 32)
        .background(Color.black)
}
