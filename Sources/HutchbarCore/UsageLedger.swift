// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Supported reporting intervals for token usage and costs.
public enum UsagePeriod: String, CaseIterable, Sendable, Codable {
  case today
  case week
  case month
}

/// Aggregated usage metrics for a reporting period.
public struct UsageSummary: Equatable, Sendable, Codable {
  public let costUSD: Double
  public let costByProvider: [AgentKind: Double]
  public let tokens: TokenUsage
  /// Cache read tokens divided by total input-related tokens (input + cacheRead + cacheWrites).
  public let cachedShare: Double
  public let hasUnknownModels: Bool
  public let unknownModelTokens: Int

  public init(
    costUSD: Double,
    costByProvider: [AgentKind: Double],
    tokens: TokenUsage,
    cachedShare: Double,
    hasUnknownModels: Bool,
    unknownModelTokens: Int = 0
  ) {
    self.costUSD = costUSD
    self.costByProvider = costByProvider
    self.tokens = tokens
    self.cachedShare = cachedShare
    self.hasUnknownModels = hasUnknownModels
    self.unknownModelTokens = unknownModelTokens
  }
}

/// A point in time along a usage dynamic series.
public struct UsagePoint: Equatable, Sendable, Codable {
  public let date: Date
  public let costUSD: Double
  public let tokens: TokenUsage
  public let costByProvider: [AgentKind: Double]

  public init(
    date: Date,
    costUSD: Double = 0.0,
    tokens: TokenUsage = .zero,
    costByProvider: [AgentKind: Double] = [:]
  ) {
    self.date = date
    self.costUSD = costUSD
    self.tokens = tokens
    self.costByProvider = costByProvider
  }
}

/// Composite key for daily provider-model aggregates.
public struct DayProviderModelKey: Hashable, Sendable, Codable {
  public let day: Date
  public let provider: AgentKind
  public let model: String

  public init(day: Date, provider: AgentKind, model: String) {
    self.day = day
    self.provider = provider
    self.model = model
  }
}

/// Composite key for daily hourly aggregates.
public struct DayHourKey: Hashable, Sendable, Codable {
  public let day: Date
  public let hour: Int

  public init(day: Date, hour: Int) {
    self.day = day
    self.hour = hour
  }
}

/// Composite key for daily hourly provider-model aggregates.
public struct DayHourProviderModelKey: Hashable, Sendable, Codable {
  public let day: Date
  public let hour: Int
  public let provider: AgentKind
  public let model: String

  public init(day: Date, hour: Int, provider: AgentKind, model: String) {
    self.day = day
    self.hour = hour
    self.provider = provider
    self.model = model
  }
}

/// An in-memory aggregation ledger for token spending and dynamics.
public struct UsageLedger: Equatable, Sendable, Codable {
  public private(set) var byDayProviderModel: [DayProviderModelKey: TokenUsage] = [:]
  public private(set) var byDayHour: [DayHourKey: TokenUsage] = [:]
  public private(set) var byDayHourProviderModel: [DayHourProviderModelKey: TokenUsage] = [:]

  public init() {}

  /// Records a single usage event.
  public mutating func record(_ event: UsageEvent) {
    let dayKey = DayProviderModelKey(day: event.day, provider: event.provider, model: event.model)
    byDayProviderModel[dayKey, default: .zero] += event.tokens

    let hourKey = DayHourKey(day: event.day, hour: event.hour)
    byDayHour[hourKey, default: .zero] += event.tokens

    let detailKey = DayHourProviderModelKey(
      day: event.day,
      hour: event.hour,
      provider: event.provider,
      model: event.model
    )
    byDayHourProviderModel[detailKey, default: .zero] += event.tokens
  }

  /// Records an array of usage events.
  public mutating func record(_ events: [UsageEvent]) {
    for event in events {
      record(event)
    }
  }

  /// Calculates the USD cost for given tokens and model using ModelPrices.
  public func cost(for model: String, tokens: TokenUsage) -> Double? {
    guard let price = ModelPrices.price(for: model) else { return nil }
    let totalUSD =
      Double(tokens.input) * price.input
      + Double(tokens.output) * price.output
      + Double(tokens.cacheWrite5m) * price.cacheWrite5m
      + Double(tokens.cacheWrite1h) * price.cacheWrite1h
      + Double(tokens.cacheRead) * price.cacheRead
    return totalUSD / 1_000_000.0
  }

  /// Calculates the USD cost for given tokens and model.
  public func cost(for tokens: TokenUsage, model: String) -> Double? {
    cost(for: model, tokens: tokens)
  }

  /// Calculates the USD cost for a usage event.
  public func cost(for event: UsageEvent) -> Double? {
    cost(for: event.model, tokens: event.tokens)
  }

  /// Calculates total cost for a day-provider-model aggregate entry.
  public func cost(for key: DayProviderModelKey) -> Double? {
    guard let tokens = byDayProviderModel[key] else { return nil }
    return cost(for: key.model, tokens: tokens)
  }

  /// Computes the summary metrics for the given period.
  public func summary(
    period: UsagePeriod,
    now: Date,
    calendar: Calendar
  ) -> UsageSummary {
    let (startDate, endDate) = dateRange(for: period, now: now, calendar: calendar)

    var totalCost: Double = 0.0
    var costByProvider: [AgentKind: Double] = [:]
    var totalTokens = TokenUsage.zero
    var unknownModelTokens = 0
    var hasUnknownModels = false

    for (key, tokens) in byDayProviderModel {
      guard key.day >= startDate, key.day < endDate else { continue }
      totalTokens += tokens

      if let entryCost = cost(for: key.model, tokens: tokens) {
        totalCost += entryCost
        costByProvider[key.provider, default: 0.0] += entryCost
      } else {
        unknownModelTokens += tokens.total
        hasUnknownModels = true
      }
    }

    let inputRelated =
      totalTokens.input + totalTokens.cacheRead + totalTokens.cacheWrite5m
      + totalTokens.cacheWrite1h
    let cachedShare: Double =
      inputRelated > 0 ? Double(totalTokens.cacheRead) / Double(inputRelated) : 0.0

    return UsageSummary(
      costUSD: totalCost,
      costByProvider: costByProvider,
      tokens: totalTokens,
      cachedShare: cachedShare,
      hasUnknownModels: hasUnknownModels,
      unknownModelTokens: unknownModelTokens
    )
  }

  /// Computes a time-series of usage points for charting.
  ///
  /// Today produces 24 hourly points; week produces 7 daily points; month produces 30 daily points.
  /// Intervals with no recorded events produce zero-filled usage points.
  public func series(
    period: UsagePeriod,
    now: Date,
    calendar: Calendar
  ) -> [UsagePoint] {
    let todayStart = calendar.startOfDay(for: now)

    switch period {
    case .today:
      var points: [UsagePoint] = []
      points.reserveCapacity(24)

      for hour in 0..<24 {
        guard let hourDate = calendar.date(byAdding: .hour, value: hour, to: todayStart) else {
          continue
        }
        var hourTokens = TokenUsage.zero
        var hourCost = 0.0
        var hourCostByProvider: [AgentKind: Double] = [:]

        for (key, tokens) in byDayHourProviderModel where key.day == todayStart && key.hour == hour
        {
          hourTokens += tokens
          if let itemCost = cost(for: key.model, tokens: tokens) {
            hourCost += itemCost
            hourCostByProvider[key.provider, default: 0.0] += itemCost
          }
        }

        points.append(
          UsagePoint(
            date: hourDate,
            costUSD: hourCost,
            tokens: hourTokens,
            costByProvider: hourCostByProvider
          )
        )
      }
      return points

    case .week, .month:
      let dayCount = period == .week ? 7 : 30
      var points: [UsagePoint] = []
      points.reserveCapacity(dayCount)

      for index in 0..<dayCount {
        let offset = index - (dayCount - 1)
        guard let dayDate = calendar.date(byAdding: .day, value: offset, to: todayStart) else {
          continue
        }
        var dayTokens = TokenUsage.zero
        var dayCost = 0.0
        var dayCostByProvider: [AgentKind: Double] = [:]

        for (key, tokens) in byDayProviderModel where key.day == dayDate {
          dayTokens += tokens
          if let itemCost = cost(for: key.model, tokens: tokens) {
            dayCost += itemCost
            dayCostByProvider[key.provider, default: 0.0] += itemCost
          }
        }

        points.append(
          UsagePoint(
            date: dayDate,
            costUSD: dayCost,
            tokens: dayTokens,
            costByProvider: dayCostByProvider
          )
        )
      }
      return points
    }
  }

  private func dateRange(
    for period: UsagePeriod,
    now: Date,
    calendar: Calendar
  ) -> (start: Date, end: Date) {
    let todayStart = calendar.startOfDay(for: now)
    let end = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart

    switch period {
    case .today:
      return (todayStart, end)
    case .week:
      let start = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
      return (start, end)
    case .month:
      let start = calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart
      return (start, end)
    }
  }
}
