//
//  SessionBarView.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import SwiftUI
import Defaults

/// Compact session progress bar shown below the notch in closed state
struct SessionBarView: View {
    let percent: Int
    let color: Color
    @ObservedObject private var extraUsage = ExtraUsageService.shared
    @ObservedObject private var statusService = ClaudeStatusService.shared

    var body: some View {
        HStack(spacing: 6) {
            // Extra usage indicator
            if extraUsage.isExtraUsageActive {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.yellow)
            }

            // Service status warning (only when there's an issue)
            if Defaults[.showServiceStatusIndicator], statusService.currentStatus.worstRelevantStatus == .majorOutage {
                Image(systemName: statusService.currentStatus.worstRelevantStatus.systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(statusService.currentStatus.worstRelevantStatus.color)
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))

                    // Progress fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(percent) / 100)
                }
            }
            .frame(height: 6)

            // Percentage text
            Text("\(percent)%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.8))
        )
    }
}

#Preview {
    VStack {
        SessionBarView(percent: 50, color: .green)
        SessionBarView(percent: 75, color: .yellow)
        SessionBarView(percent: 95, color: .red)
    }
    .frame(width: 200)
    .padding()
    .background(Color.gray)
}
