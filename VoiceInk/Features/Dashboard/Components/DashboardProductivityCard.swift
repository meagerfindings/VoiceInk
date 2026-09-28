import Foundation
import SwiftUI

struct DashboardProductivityCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let period: DashboardInsightPeriod
    let points: [DashboardProductivityPoint]
    let updatedAtText: String
    let isRefreshingStats: Bool
    let onRefreshStats: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 16) {
                Text(period.chartTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.84)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isRefreshingStats)

                    DashboardStatsRefreshButton(
                        isRefreshing: isRefreshingStats,
                        action: onRefreshStats
                    )
                }
                .frame(maxWidth: 260, alignment: .trailing)
            }

            DashboardProductivityChart(period: period, points: points)
                .frame(height: 208)
        }
        .dashboardInsightCardStyle()
    }

    private var statusText: String {
        isRefreshingStats ? String(localized: "Updating") : updatedAtText
    }
}

private struct DashboardStatsRefreshButton: View {
    let isRefreshing: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppTheme.Accent.primary)
                        .transition(.opacity)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .transition(.opacity)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(DashboardInsightButtonStyle())
        .disabled(isRefreshing)
        .help(refreshHelp)
        .accessibilityLabel(Text(refreshHelp))
    }

    private var refreshHelp: String {
        isRefreshing ? String(localized: "Refreshing stats") : String(localized: "Refresh stats")
    }
}

private enum DashboardProductivityChartData {
    static func visiblePoints(
        for period: DashboardInsightPeriod,
        points: [DashboardProductivityPoint],
        now: Date = Date()
    ) -> [DashboardProductivityPoint] {
        guard period == .today, let firstPoint = points.first else {
            return points
        }

        let calendar = DashboardPeriodWindows.dashboardCalendar()

        guard calendar.isDate(firstPoint.date, inSameDayAs: now) else {
            return points
        }

        return Array(points.prefix(calendar.component(.hour, from: now) + 1))
    }

    static func yAxisUpperBound(for value: Int) -> Int {
        guard value > 0 else {
            return 0
        }

        let paddedValue = Double(value) * 1.06
        let magnitude = pow(10, max(0, floor(log10(paddedValue)) - 1))
        let step = max(1, Int(magnitude))

        return max(value, Int(ceil(paddedValue / Double(step))) * step)
    }
}

private struct DashboardProductivityChart: View {
    let period: DashboardInsightPeriod
    let points: [DashboardProductivityPoint]

    private func yAxisLabels(upperBound: Int, hasWords: Bool) -> [Int] {
        guard hasWords else {
            return [0]
        }

        return [
            upperBound,
            upperBound * 3 / 4,
            upperBound / 2,
            upperBound / 4,
            0,
        ]
        .reduce(into: []) { labels, value in
            if !labels.contains(value) {
                labels.append(value)
            }
        }
    }

    var body: some View {
        let visiblePoints = DashboardProductivityChartData.visiblePoints(for: period, points: points)
        let upperBound = DashboardProductivityChartData.yAxisUpperBound(for: visiblePoints.lazy.map(\.words).max() ?? 0)
        let labels = yAxisLabels(upperBound: upperBound, hasWords: visiblePoints.contains { $0.words > 0 })

        HStack(alignment: .top, spacing: 12) {
            DashboardProductivityYAxis(labels: labels)
                .accessibilityHidden(true)

            DashboardProductivityPlotArea(
                period: period,
                points: points,
                visiblePoints: visiblePoints,
                yAxisUpperBound: upperBound,
                horizontalSlotCount: period == .today ? 24 : max(visiblePoints.count, 1)
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dictated words chart")
        .accessibilityValue(totalWordsAccessibilityValue)
    }

    private var totalWordsAccessibilityValue: String {
        String(
            format: String(localized: "%@ words"),
            Formatters.formattedNumber(points.reduce(0) { $0 + $1.words })
        )
    }
}

private struct DashboardProductivityYAxis: View {
    let labels: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if labels.count == 1, let label = labels.first {
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    yAxisLabel(label)
                }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(labels, id: \.self) { label in
                        yAxisLabel(label)
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }

            Text("Words")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .frame(height: 30, alignment: .topLeading)
        }
        .frame(width: 42, alignment: .leading)
    }

    private func yAxisLabel(_ label: Int) -> some View {
        Text(Formatters.formattedAxisValue(label))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
    }
}
