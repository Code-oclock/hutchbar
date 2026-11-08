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
      let currentHour = PanelV2Logic.currentHourIndex()

      HStack(alignment: .bottom, spacing: barSpacing(for: points.count)) {
        ForEach(points.indices, id: \.self) { index in
          let point = points[index]
          let isHovered = hoveredPoint?.date == point.date
          let isCurrentHour = (usage.period == .today && index == currentHour)

          GeometryReader { geo in
            let availableHeight = geo.size.height

            VStack {
              Spacer(minLength: 0)
              if point.costUSD > 0 {
                let heightRatio = min(1.0, max(0.0, point.costUSD / maxCost))
                let barHeight = max(4.0, availableHeight * CGFloat(heightRatio))
                RoundedRectangle(cornerRadius: 1.5)
                  .fill(
                    isHovered || isCurrentHour
                      ? Color.accentColor : Color.accentColor.opacity(0.75)
                  )
                  .frame(height: barHeight)
              } else {
                Circle()
                  .fill(
                    isHovered || isCurrentHour
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

      let labels = PanelV2Logic.formatTrendAxisLabels(
        period: usage.period,
        points: points
      )
      axisLabelsView(labels: labels, currentHour: currentHour)
    }
  }

  @ViewBuilder
  private func axisLabelsView(
    labels: (leading: String, trailing: String),
    currentHour: Int
  ) -> some View {
    if usage.period == .today {
      ZStack {
        HStack {
          Text(labels.leading)
            .font(.caption2)
            .fontWeight(currentHour == 0 ? .semibold : .regular)
            .foregroundStyle(currentHour == 0 ? Color.accentColor : .secondary)
          Spacer()
          Text(labels.trailing)
            .font(.caption2)
            .fontWeight(currentHour == 23 ? .semibold : .regular)
            .foregroundStyle(currentHour == 23 ? Color.accentColor : .secondary)
        }

        if currentHour > 2 && currentHour < 21 {  // keep clear of the edge labels
          GeometryReader { geo in
            let markerX = (CGFloat(currentHour) + 0.5) / 24.0 * geo.size.width
            Text(PanelV2Logic.formatHourLabel(hour: currentHour))
              .font(.caption2)
              .fontWeight(.semibold)
              .foregroundStyle(Color.accentColor)
              .position(x: min(max(markerX, 26), geo.size.width - 26), y: geo.size.height / 2)
          }
        }
      }
      .frame(height: 14)
    } else {
      HStack {
        Text(labels.leading)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Text(labels.trailing)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
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
