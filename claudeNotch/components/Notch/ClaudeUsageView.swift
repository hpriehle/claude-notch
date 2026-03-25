//
//  ClaudeUsageView.swift
//  claudeNotch
//
//  Created by Harrison Riehle on 2026. 01. 14..
//

import SwiftUI
import Defaults
import AppKit

/// Expanded view showing full Claude usage statistics, with a second history page.
struct ClaudeUsageView: View {
    @EnvironmentObject var vm: ClaudeViewModel
    @ObservedObject private var usageService = ClaudeUsageService.shared
    @ObservedObject private var extraUsage = ExtraUsageService.shared

    // Set to false to disable the history page entirely (safe kill switch)
    private static let historyPageEnabled = true
    private let pageCount = 2

    @State private var selectedPage: Int = 0
    private let pageDetector = HorizontalScrollPageDetector()

    var body: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    usagePage
                        .frame(width: geo.size.width)
                    if Self.historyPageEnabled {
                        UsageHistoryView()
                            .frame(width: geo.size.width)
                    }
                }
                .offset(x: -CGFloat(selectedPage) * geo.size.width)
                .animation(.spring(response: 0.38, dampingFraction: 0.85), value: selectedPage)
            }
            .clipped()

            if Self.historyPageEnabled {
                pageDots
                    .padding(.bottom, 8)
            }
        }
        .onChange(of: vm.notchState) { _, newState in
            if newState == .open {
                startPageDetector()
            } else {
                stopPageDetector()
                selectedPage = 0
            }
        }
        .onAppear {
            if vm.notchState == .open { startPageDetector() }
        }
        .onDisappear {
            stopPageDetector()
        }
    }

    // MARK: - Page 0: existing usage content (unchanged logic)

    private var usagePage: some View {
        VStack(alignment: .leading, spacing: extraUsage.isExtraUsageActive ? 8 : 12) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text("Claude Usage")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)

                if extraUsage.isExtraUsageActive {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                        Text("2x")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow)
                    .cornerRadius(6)
                }

                Spacer()

                // Refresh button
                Button(action: {
                    usageService.refresh()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(usageService.isRefreshing ? .white : .gray)
                        .rotationEffect(.degrees(usageService.isRefreshing ? 360 : 0))
                        .animation(usageService.isRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: usageService.isRefreshing)
                }
                .buttonStyle(.plain)
                .disabled(usageService.isRefreshing)
                .help("Refresh usage data")

                ConnectionStatusView(
                    isConnected: vm.usageData.isOAuthConnected || usageService.hasOAuthData,
                    isLoading: usageService.isInitialFetchInProgress
                )
            }
            .padding(.bottom, 4)

            // Warning banner for API errors (e.g. 429 rate limit)
            if let error = usageService.lastRefreshError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange.opacity(0.9))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(8)
            }

            // Extra usage countdown
            if extraUsage.isExtraUsageActive, let endsAt = extraUsage.extraUsageEndsAt {
                ExtraUsageCountdownView(endsAt: endsAt)
            }

            // Show loading only while the initial API call is in flight
            if usageService.isInitialFetchInProgress {
                LoadingUsageView()
            } else if !vm.usageData.hasAnyData {
                EmptyUsageView()
            } else {
                // Session Usage
                let sessionPercent = vm.usageData.oauthSessionPercent
                if Defaults[.showSessionUsage], let sessionPercent = sessionPercent {
                    UsageBarView(
                        label: "Session",
                        percent: sessionPercent,
                        resetTime: vm.usageData.displaySessionResetTime,
                        color: vm.usageData.colorForPercent(sessionPercent)
                    )
                }

                // Weekly All Models Usage
                let weeklyAllPercent = vm.usageData.oauthWeeklyAllPercent
                if Defaults[.showWeeklyAllUsage], let weeklyAllPercent = weeklyAllPercent {
                    UsageBarView(
                        label: "Weekly (All Models)",
                        percent: weeklyAllPercent,
                        resetTime: vm.usageData.displayWeeklyAllResetTime,
                        color: vm.usageData.colorForPercent(weeklyAllPercent)
                    )
                }

                // Weekly Sonnet Usage (default to 0% when OAuth is connected but no Sonnet-specific value available)
                let weeklySonnetPercent = vm.usageData.oauthWeeklySonnetPercent
                    ?? (vm.usageData.hasOAuthData ? 0 : nil)
                if Defaults[.showWeeklySonnetUsage], let weeklySonnetPercent = weeklySonnetPercent {
                    UsageBarView(
                        label: "Weekly (Sonnet)",
                        percent: weeklySonnetPercent,
                        resetTime: vm.usageData.displayWeeklySonnetResetTime,
                        color: vm.usageData.colorForPercent(weeklySonnetPercent)
                    )
                }

                // Show code stats when available
                if vm.usageData.hasCodeData {
                    CodeUsageView(usageData: vm.usageData)
                }
            }
        }
        .padding(.horizontal, 28)  // Avoid corner clipping (corner radius is 24pt)
        .padding(.top, extraUsage.isExtraUsageActive ? 12 : 16)
        .padding(.bottom, extraUsage.isExtraUsageActive ? 20 : 28)
    }

    // MARK: - Page indicator dots

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { idx in
                Button(action: {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                        selectedPage = idx
                    }
                }) {
                    Circle()
                        .fill(idx == selectedPage
                              ? Color.white.opacity(0.8)
                              : Color.white.opacity(0.25))
                        .frame(
                            width:  idx == selectedPage ? 6 : 4,
                            height: idx == selectedPage ? 6 : 4
                        )
                        .animation(.easeInOut(duration: 0.15), value: selectedPage)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Scroll detector

    private func startPageDetector() {
        guard Self.historyPageEnabled else { return }
        pageDetector.onPageChange = { [self] direction in
            let next = max(0, min(pageCount - 1, selectedPage + direction))
            withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) {
                selectedPage = next
            }
        }
        pageDetector.start()
    }

    private func stopPageDetector() {
        pageDetector.stop()
    }
}

/// Loading state while OAuth data is being fetched
struct LoadingUsageView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(.gray)
            Text("Loading usage data...")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
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
            Text("Connect via Settings → Claude")
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
    var isLoading: Bool = false

    var body: some View {
        if isLoading {
            // Loading initial data from API
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(.gray)
                Text("Loading…")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.05))
            .cornerRadius(8)
        } else if isConnected {
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
        } else {
            // Not connected - open Settings to Claude section
            Button(action: {
                SettingsWindowController.shared.showWindow()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.system(size: 9))
                    Text("Settings")
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

/// Countdown showing when extra usage ends
struct ExtraUsageCountdownView: View {
    let endsAt: Date

    @State private var displayText: String = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 10))
                .foregroundColor(.yellow)
            Text("Extra usage ends in \(displayText)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.yellow.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.1))
        .cornerRadius(8)
        .onAppear { updateText() }
        .onReceive(timer) { _ in updateText() }
    }

    private func updateText() {
        let interval = endsAt.timeIntervalSinceNow
        guard interval > 0 else { displayText = "soon"; return }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            displayText = "\(hours)h \(minutes)m"
        } else {
            displayText = "\(minutes)m"
        }
    }
}

#Preview {
    ClaudeUsageView()
        .environmentObject(ClaudeViewModel())
        .frame(width: 400, height: 200)
        .background(Color.black)
}
