//
//  UsageHistoryView.swift
//  claudeNotch
//
//  GitHub-style hourly usage history grid.
//  Layout: 7 rows (days, oldest at top) × 24 columns (hours, midnight at left).
//  At cellSize=9, gap=2: grid is 264pt wide × 77pt tall — fits the 640×300pt notch.
//

import SwiftUI

struct UsageHistoryView: View {
    @EnvironmentObject var vm: ClaudeViewModel
    @StateObject private var store = UsageHistoryStoreObservable.shared

    @State private var selectedMetric: HistoryMetric = .session
    @State private var hoveredCell: (day: Int, hour: Int)? = nil

    private let cellSize: CGFloat = 9
    private let cellGap: CGFloat  = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            gridSection
            legendRow
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 20)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("Usage History")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            metricPicker
        }
    }

    private var metricPicker: some View {
        HStack(spacing: 0) {
            ForEach(HistoryMetric.allCases, id: \.self) { metric in
                Button(action: { selectedMetric = metric }) {
                    Text(metric.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(selectedMetric == metric ? .black : .gray)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            selectedMetric == metric
                                ? Color.white.opacity(0.85)
                                : Color.clear
                        )
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color.white.opacity(0.1))
        .cornerRadius(5)
    }

    // MARK: - Grid

    private var gridSection: some View {
        let grid = store.grid()

        return VStack(alignment: .leading, spacing: 4) {
            // Hour labels (0, 6, 12, 18)
            hourLabels

            // 7 rows (days) × 24 columns (hours)
            VStack(spacing: cellGap) {
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: cellGap) {
                        // Day label (3-char)
                        Text(dayLabel(day))
                            .font(.system(size: 7))
                            .foregroundColor(.gray)
                            .frame(width: 18, alignment: .leading)

                        ForEach(0..<24, id: \.self) { hour in
                            let snap = grid[day][hour]
                            let pct  = snap.map { selectedMetric.value(from: $0) }
                            HistoryCellView(
                                percent:   pct,
                                isHovered: hoveredCell?.day == day && hoveredCell?.hour == hour
                            )
                            .onHover { hovering in
                                hoveredCell = hovering ? (day: day, hour: hour) : nil
                            }
                        }
                    }
                }
            }

            // Tooltip row
            tooltipRow(grid: grid)
        }
    }

    private var hourLabels: some View {
        HStack(spacing: cellGap) {
            Color.clear.frame(width: 18)  // spacer aligning with day labels
            ForEach(0..<24, id: \.self) { hour in
                Group {
                    if hour % 6 == 0 {
                        Text("\(hour)")
                            .font(.system(size: 7))
                            .foregroundColor(.gray)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: cellSize)
            }
        }
    }

    private func tooltipRow(grid: [[UsageSnapshot?]]) -> some View {
        Group {
            if let h = hoveredCell {
                let snap = grid[h.day][h.hour]
                HStack(spacing: 4) {
                    Text(cellLabel(day: h.day, hour: h.hour))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    if let s = snap {
                        Text("·")
                            .foregroundColor(.gray)
                        Text("\(selectedMetric.value(from: s))%")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(vm.usageData.colorForPercent(selectedMetric.value(from: s)))
                    } else {
                        Text("· No data")
                            .font(.system(size: 9))
                            .foregroundColor(.gray)
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(height: 14)
    }

    // MARK: - Legend

    private var legendRow: some View {
        HStack(spacing: 6) {
            Text("Less")
                .font(.system(size: 9))
                .foregroundColor(.gray)
            ForEach([0, 25, 50, 75, 100], id: \.self) { pct in
                HistoryCellView(percent: pct == 0 ? nil : pct, isHovered: false)
            }
            Text("More")
                .font(.system(size: 9))
                .foregroundColor(.gray)
            Spacer()
            if store.snapshots.isEmpty {
                Text("Collecting data…")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: - Helpers

    private func dayLabel(_ dayIdx: Int) -> String {
        let labels = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let cal = Calendar.current
        guard let date = cal.date(byAdding: .day, value: -(6 - dayIdx), to: Date()) else {
            return "???"
        }
        let weekday = cal.component(.weekday, from: date) - 1
        return labels[weekday]
    }

    private func cellLabel(day: Int, hour: Int) -> String {
        let cal = Calendar.current
        guard let date = cal.date(byAdding: .day, value: -(6 - day), to: Date()) else { return "--" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: date)) \(String(format: "%02d:00", hour))"
    }
}

// MARK: - Cell View

private struct HistoryCellView: View {
    let percent: Int?
    let isHovered: Bool

    private let size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fillColor)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(isHovered ? 0.7 : 0), lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.3 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isHovered)
    }

    private var fillColor: Color {
        guard let pct = percent else {
            return Color.white.opacity(0.08)
        }
        let base: Color
        switch pct {
        case 0..<50:  base = Color(red: 16/255,  green: 185/255, blue: 129/255)  // green
        case 50..<80: base = Color(red: 245/255, green: 158/255, blue: 11/255)   // amber
        case 80..<95: base = Color(red: 249/255, green: 115/255, blue: 22/255)   // orange
        default:      base = Color(red: 239/255, green: 68/255,  blue: 68/255)   // red
        }
        let opacity = 0.25 + (Double(pct) / 100.0) * 0.75
        return base.opacity(opacity)
    }
}

#Preview {
    UsageHistoryView()
        .environmentObject(ClaudeViewModel())
        .frame(width: 640, height: 300)
        .background(Color.black)
}
