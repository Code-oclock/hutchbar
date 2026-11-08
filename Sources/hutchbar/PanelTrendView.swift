// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import SwiftUI

/// Dynamics trend chart displaying usage history bars for the selected period.
struct PanelTrendView: View {
  let usage: UsageViewModel

  init(usage: UsageViewModel) {
    self.usage = usage
  }

  private var hoveredPointState = SwiftUI.State<UsagePoint?>(initialValue: nil)

  private var hoveredPoint: UsagePoint? {
    get { hoveredPointState.wrappedValue }
    nonmutating set { hoveredPointState.wrappedValue = newValue }
  }

  var body: some View {
    PanelCardView {
      chartHeader

      let points = currentPoints
      if points.isEmpty {
        emptyTrendState
      } else {
        trendChart(points: points)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
  }

  private var currentPoints: [UsagePoint] {
    usage.ledger?.series(period: usage.period, now: Date(), calendar: .current) ?? []
  }

  private var chartHeader: some View {
    HStack {
      Text(L10n.trendTitle())
        .font(.subheadline)
        .fontWeight(.semibold)

      Spacer()

      if let hovered = hoveredPoint {
        Text("\(formatDate(hovered.date)): \(PanelV2Logic.formatCurrency(amount: hovered.costUSD))")
          .font(.caption2)
          .fontWeight(.medium)
          .foregroundStyle(.primary)
      }
    }
  }

  private func trendChart(points: [UsagePoint]) -> some View {
    VStack(spacing: 4) {
      let maxCost = max(points.map(\.costUSD).max() ?? 0.0, 0.001)

      HStack(alignment: .bottom, spacing: barSpacing(for: points.count)) {
        ForEach(points.indices, id: \.self) { index in
          let point = points[index]
          let isHovered = hoveredPoint?.date == point.date
          let isCurrent = isCurrentPoint(index: index, point: point)

          GeometryReader { geo in
            let availableHeight = geo.size.height

            VStack {
              Spacer(minLength: 0)
              if point.costUSD > 0 {
                let heightRatio = min(1.0, max(0.0, point.costUSD / maxCost))
                let barHeight = max(4.0, availableHeight * CGFloat(heightRatio))
                RoundedRectangle(cornerRadius: 1.5)
                  .fill(
                    isHovered || isCurrent
                      ? Color.accentColor : Color.accentColor.opacity(0.75)
                  )
                  .frame(height: barHeight)
              } else {
                Circle()
                  .fill(
                    isHovered || isCurrent
                      ? Color.accentColor : Color.secondary.opacity(0.35)
                  )
                  .frame(width: 2.5, height: 2.5)
                  .padding(.bottom, 1)
              }
            }
            .frame(maxWidth: .infinity)
          }
          .contentShape(Rectangle())
          .onHover { hovering in
            if hovering {
              hoveredPoint = point
            } else if hoveredPoint?.date == point.date {
              hoveredPoint = nil
            }
          }
          .help("\(formatDate(point.date)): \(PanelV2Logic.formatCurrency(amount: point.costUSD))")
        }
      }
      .frame(height: 48)

      let labels = PanelV2Logic.trendAxisLabels(
        period: usage.period,
        points: points
      )
      axisLabelsView(labels: labels)
    }
  }

  @ViewBuilder
  private func axisLabelsView(
    labels: TrendAxisLabels
  ) -> some View {
    HStack {
      Text(labels.leading.text)
        .font(.caption2)
        .fontWeight(labels.leading.isCurrent ? .semibold : .regular)
        .foregroundStyle(labels.leading.isCurrent ? Color.accentColor : .secondary)

      Spacer()

      if let middle = labels.middle {
        Text(middle.text)
          .font(.caption2)
          .fontWeight(middle.isCurrent ? .semibold : .regular)
          .foregroundStyle(middle.isCurrent ? Color.accentColor : .secondary)

        Spacer()
      }

      Text(labels.trailing.text)
        .font(.caption2)
        .fontWeight(labels.trailing.isCurrent ? .semibold : .regular)
        .foregroundStyle(labels.trailing.isCurrent ? Color.accentColor : .secondary)
    }
    .frame(height: 14)
  }

  private func isCurrentPoint(index: Int, point: UsagePoint) -> Bool {
    switch usage.period {
    case .today:
      return index == PanelV2Logic.currentHourIndex()
    case .week, .month:
      return Calendar.current.isDateInToday(point.date)
    }
  }

  private func barSpacing(for count: Int) -> CGFloat {
    if count <= 7 {
      return 6.0
    }
    if count <= 24 {
      return 2.5
    }
    return 1.5
  }

  private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    switch usage.period {
    case .today:
      formatter.dateFormat = "HH:mm"
    case .week, .month:
      formatter.dateFormat = "d MMM"
    }
    return formatter.string(from: date)
  }

  private var emptyTrendState: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(L10n.emptySpending())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }
}
