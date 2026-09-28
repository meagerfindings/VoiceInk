import Foundation
import SwiftUI

struct DashboardProductivityPlotGeometry {
    let pointCount: Int
    let horizontalSlotCount: Int
    let yAxisUpperBound: Int
    let size: CGSize

    func xPosition(for index: Int) -> CGFloat {
        let slotCount = max(horizontalSlotCount, pointCount)
        guard slotCount > 1 else { return size.width / 2 }
        return size.width * CGFloat(index) / CGFloat(slotCount - 1)
    }

    func point(for index: Int, words: Int) -> CGPoint {
        let maximum = max(yAxisUpperBound, 1)
        let progress = min(max(CGFloat(words) / CGFloat(maximum), 0), 1)
        return CGPoint(
            x: xPosition(for: index),
            y: size.height - (size.height * progress)
        )
    }
}

struct DashboardProductivityTrendLayer: View {
    let points: [DashboardProductivityPoint]
    let yAxisUpperBound: Int
    let horizontalSlotCount: Int
    let hoveredPointID: Date?

    private let lineTint = AppTheme.Insights.productivity

    private var hasVisibleData: Bool {
        points.contains { $0.words > 0 }
    }

    var body: some View {
        GeometryReader { geometry in
            let renderedPoints = Self.renderedPoints(
                for: points,
                yAxisUpperBound: yAxisUpperBound,
                horizontalSlotCount: horizontalSlotCount,
                size: geometry.size
            )

            ZStack(alignment: .topLeading) {
                if !renderedPoints.isEmpty {
                    if hasVisibleData {
                        DashboardProductivityAreaFillShape(points: renderedPoints)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        lineTint.opacity(0.24),
                                        lineTint.opacity(0.07),
                                        lineTint.opacity(0.0),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        DashboardProductivityTrendLineShape(points: renderedPoints)
                            .stroke(
                                lineTint,
                                style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                            )

                        if let latestPoint = renderedPoints.last {
                            DashboardProductivityCurrentValueMarker(tint: lineTint)
                                .position(x: latestPoint.x, y: latestPoint.y)
                        }

                        if let hoveredIndex = points.firstIndex(where: { $0.id == hoveredPointID }),
                            renderedPoints.indices.contains(hoveredIndex)
                        {
                            let hoveredPoint = renderedPoints[hoveredIndex]

                            Rectangle()
                                .fill(AppTheme.Insights.border)
                                .frame(width: 1, height: geometry.size.height)
                                .position(x: hoveredPoint.x, y: geometry.size.height / 2)

                            Circle()
                                .fill(lineTint)
                                .stroke(AppTheme.Insights.card, lineWidth: 2)
                                .frame(width: 9, height: 9)
                                .position(x: hoveredPoint.x, y: hoveredPoint.y)
                        }
                    } else {
                        DashboardProductivityBaselineShape()
                            .stroke(
                                AppTheme.Text.secondary.opacity(0.22),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round)
                            )
                    }
                }
            }
        }
    }

    private static func renderedPoints(
        for points: [DashboardProductivityPoint],
        yAxisUpperBound: Int,
        horizontalSlotCount: Int,
        size: CGSize
    ) -> [CGPoint] {
        guard !points.isEmpty, size.width > 0, size.height > 0 else {
            return []
        }

        let geometry = DashboardProductivityPlotGeometry(
            pointCount: points.count,
            horizontalSlotCount: horizontalSlotCount,
            yAxisUpperBound: yAxisUpperBound,
            size: size
        )

        return points.enumerated().map { index, point in
            geometry.point(for: index, words: point.words)
        }
    }
}

struct DashboardProductivityGrid: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { index in
                Rectangle()
                    .fill(AppTheme.Insights.grid)
                    .frame(height: 1)

                if index < 4 {
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct DashboardProductivityAreaFillShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        guard let first = points.first else {
            return Path()
        }

        if points.count == 1 {
            let halfWidth = min(max(rect.width * 0.055, 10), 20)
            let left = max(rect.minX, first.x - halfWidth)
            let right = min(rect.maxX, first.x + halfWidth)

            var path = Path()
            path.move(to: CGPoint(x: left, y: rect.maxY))
            path.addCurve(
                to: first,
                control1: CGPoint(x: left, y: first.y),
                control2: CGPoint(x: first.x - halfWidth * 0.48, y: first.y)
            )
            path.addCurve(
                to: CGPoint(x: right, y: rect.maxY),
                control1: CGPoint(x: first.x + halfWidth * 0.48, y: first.y),
                control2: CGPoint(x: right, y: first.y)
            )
            path.closeSubpath()
            return path
        }

        var path = DashboardProductivityTrendLineShape(points: points).path(in: rect)
        if let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct DashboardProductivityTrendLineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        guard let first = points.first else {
            return Path()
        }

        var path = Path()
        path.move(to: first)

        guard points.count > 1 else {
            return path
        }

        let tangents = monotoneTangents(for: points)

        for index in 0..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let distance = next.x - current.x
            let control1 = CGPoint(
                x: current.x + distance / 3,
                y: current.y + tangents[index] * distance / 3
            )
            let control2 = CGPoint(
                x: next.x - distance / 3,
                y: next.y - tangents[index + 1] * distance / 3
            )

            path.addCurve(
                to: next,
                control1: control1,
                control2: control2
            )
        }

        return path
    }

    private func monotoneTangents(for points: [CGPoint]) -> [CGFloat] {
        guard points.count > 1 else {
            return Array(repeating: 0, count: points.count)
        }

        let slopes = (0..<(points.count - 1)).map { index -> CGFloat in
            let current = points[index]
            let next = points[index + 1]
            let distance = next.x - current.x

            guard abs(distance) > .ulpOfOne else {
                return 0
            }

            return (next.y - current.y) / distance
        }

        var tangents = Array(repeating: CGFloat(0), count: points.count)
        tangents[0] = slopes[0]
        tangents[points.count - 1] = slopes[slopes.count - 1]

        guard points.count > 2 else {
            return tangents
        }

        for index in 1..<(points.count - 1) {
            let previousSlope = slopes[index - 1]
            let nextSlope = slopes[index]

            if previousSlope == 0 || nextSlope == 0 || previousSlope * nextSlope < 0 {
                tangents[index] = 0
            } else {
                tangents[index] = (previousSlope + nextSlope) / 2
            }
        }

        for index in slopes.indices {
            let slope = slopes[index]

            if slope == 0 {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }

            let firstRatio = tangents[index] / slope
            let secondRatio = tangents[index + 1] / slope
            let sum = firstRatio * firstRatio + secondRatio * secondRatio

            if sum > 9 {
                let scale = 3 / sqrt(sum)
                tangents[index] = scale * firstRatio * slope
                tangents[index + 1] = scale * secondRatio * slope
            }
        }

        return tangents
    }
}

private struct DashboardProductivityBaselineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private struct DashboardProductivityCurrentValueMarker: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.Insights.card)
                .frame(width: 10, height: 10)

            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Circle()
                .stroke(tint.opacity(0.20), lineWidth: 3)
                .frame(width: 14, height: 14)
        }
        .accessibilityHidden(true)
    }
}
