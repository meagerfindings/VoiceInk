import SwiftUI

struct ModelInsightPanelHeader: View {
    let title: LocalizedStringKey
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.headline.weight(.semibold))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(DashboardInsightButtonStyle())
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .frame(height: QuickPanelMetrics.headerHeight)
    }
}

struct RecommendedModelsFooter: View {
    var body: some View {
        HStack {
            Spacer()

            Button(action: ModelLinks.openRecommendedModels) {
                ModelActionLabel(
                    title: "Recommended Models",
                    icon: "sparkles",
                    isPrimary: true
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: true)
            .help(String(localized: "Open recommended AI models"))
        }
        .padding(.horizontal, 20)
        .frame(height: QuickPanelMetrics.footerHeight)
    }
}

struct ModelInsightDetailSection<Row: Identifiable, RowContent: View>: View {
    let title: LocalizedStringKey
    let valueTitle: LocalizedStringKey
    let valueColumnWidth: CGFloat
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let rows: [Row]
    private let rowContent: (Row) -> RowContent

    init(
        title: LocalizedStringKey,
        valueTitle: LocalizedStringKey,
        valueColumnWidth: CGFloat,
        emptyTitle: LocalizedStringKey,
        emptyIcon: String,
        rows: [Row],
        @ViewBuilder rowContent: @escaping (Row) -> RowContent
    ) {
        self.title = title
        self.valueTitle = valueTitle
        self.valueColumnWidth = valueColumnWidth
        self.emptyTitle = emptyTitle
        self.emptyIcon = emptyIcon
        self.rows = rows
        self.rowContent = rowContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(valueTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(width: valueColumnWidth, alignment: .trailing)
                    .padding(.trailing, 4)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(AppTheme.Text.primary)
            .lineLimit(1)

            if rows.isEmpty {
                InsightEmptyState(title: emptyTitle, icon: emptyIcon)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        rowContent(row)
                    }
                }
            }
        }
        .dashboardInsightCardStyle(padding: 14, alignment: .topLeading)
    }
}

struct ModelInsightPanelEmptyState: View {
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary)

            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
