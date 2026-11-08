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
  public let tokensByProvider: [AgentKind: TokenUsage]
  public let unknownTokensByProvider: [AgentKind: Int]

  public init(
    costUSD: Double,
    costByProvider: [AgentKind: Double],
    tokens: TokenUsage,
    cachedShare: Double,
    hasUnknownModels: Bool,
    unknownModelTokens: Int = 0,
    tokensByProvider: [AgentKind: TokenUsage] = [:],
    unknownTokensByProvider: [AgentKind: Int] = [:]
  ) {
    self.costUSD = costUSD
    self.costByProvider = costByProvider
    self.tokens = tokens
    self.cachedShare = cachedShare
    self.hasUnknownModels = hasUnknownModels
    self.unknownModelTokens = unknownModelTokens
    self.tokensByProvider = tokensByProvider
    self.unknownTokensByProvider = unknownTokensByProvider
  }

  /// Formatted spending description for a provider.
  public func spendingText(
    for provider: AgentKind,
    locale: Locale = .current,
    language: L10n.Language = L10n.currentLanguage()
  ) -> String {
    PanelV2Logic.providerSpendingText(
      cost: costByProvider[provider],
      totalTokens: tokensByProvider[provider]?.total ?? 0,
      unknownTokens: unknownTokensByProvider[provider] ?? 0,
      locale: locale,
      language: language
    )
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
  public private(set) var costByDayProviderModel: [DayProviderModelKey: Double] = [:]
  public private(set) var unpricedTokensByDayProviderModel: [DayProviderModelKey: Int] = [:]
  public private(set) var costByDayHourProviderModel: [DayHourProviderModelKey: Double] = [:]
  public private(set) var unpricedTokensByDayHourProviderModel: [DayHourProviderModelKey: Int] = [:]

  public init() {}

  enum CodingKeys: String, CodingKey {
    case byDayProviderModel
    case byDayHour
    case byDayHourProviderModel
    case costByDayProviderModel
    case unpricedTokensByDayProviderModel
    case costByDayHourProviderModel
    case unpricedTokensByDayHourProviderModel
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    byDayProviderModel =
      try container.decodeIfPresent(
        [DayProviderModelKey: TokenUsage].self,
        forKey: .byDayProviderModel
      ) ?? [:]
    byDayHour =
      try container.decodeIfPresent([DayHourKey: TokenUsage].self, forKey: .byDayHour) ?? [:]
    byDayHourProviderModel =
      try container.decodeIfPresent(
        [DayHourProviderModelKey: TokenUsage].self,
        forKey: .byDayHourProviderModel
      ) ?? [:]
    costByDayProviderModel =
      try container.decodeIfPresent(
        [DayProviderModelKey: Double].self,
        forKey: .costByDayProviderModel
      ) ?? [:]
    unpricedTokensByDayProviderModel =
      try container.decodeIfPresent(
        [DayProviderModelKey: Int].self,
        forKey: .unpricedTokensByDayProviderModel
      ) ?? [:]
    costByDayHourProviderModel =
      try container.decodeIfPresent(
        [DayHourProviderModelKey: Double].self,
        forKey: .costByDayHourProviderModel
      ) ?? [:]
    unpricedTokensByDayHourProviderModel =
      try container.decodeIfPresent(
        [DayHourProviderModelKey: Int].self,
        forKey: .unpricedTokensByDayHourProviderModel
      ) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(byDayProviderModel, forKey: .byDayProviderModel)
    try container.encode(byDayHour, forKey: .byDayHour)
    try container.encode(byDayHourProviderModel, forKey: .byDayHourProviderModel)
    try container.encode(costByDayProviderModel, forKey: .costByDayProviderModel)
    try container.encode(
      unpricedTokensByDayProviderModel, forKey: .unpricedTokensByDayProviderModel)
    try container.encode(costByDayHourProviderModel, forKey: .costByDayHourProviderModel)
    try container.encode(
      unpricedTokensByDayHourProviderModel,
      forKey: .unpricedTokensByDayHourProviderModel
    )
  }

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

    if let eventCost = ModelPriceTable.cost(
      model: event.model,
      tokens: event.tokens,
      isFast: event.isFast
    ) {
      costByDayProviderModel[dayKey, default: 0.0] += eventCost
      costByDayHourProviderModel[detailKey, default: 0.0] += eventCost
    } else {
      unpricedTokensByDayProviderModel[dayKey, default: 0] += event.tokens.total
      unpricedTokensByDayHourProviderModel[detailKey, default: 0] += event.tokens.total
    }
  }

  /// Records an array of usage events.
  public mutating func record(_ events: [UsageEvent]) {
    for event in events {
      record(event)
    }
  }

  /// Calculates the USD cost for given tokens and model using ModelPriceTable.
  public func cost(for model: String, tokens: TokenUsage) -> Double? {
    ModelPriceTable.cost(model: model, tokens: tokens, isFast: false)
  }

  /// Calculates the USD cost for given tokens and model.
  public func cost(for tokens: TokenUsage, model: String) -> Double? {
    cost(for: model, tokens: tokens)
  }

  /// Calculates the USD cost for a usage event.
  public func cost(for event: UsageEvent) -> Double? {
    ModelPriceTable.cost(model: event.model, tokens: event.tokens, isFast: event.isFast)
  }

  /// Calculates total cost for a day-provider-model aggregate entry.
  public func cost(for key: DayProviderModelKey) -> Double? {
    guard byDayProviderModel[key] != nil else { return nil }
    if let unpriced = unpricedTokensByDayProviderModel[key], unpriced > 0 {
      return nil
    }
    return costByDayProviderModel[key] ?? 0.0
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
    var tokensByProvider: [AgentKind: TokenUsage] = [:]
    var unknownTokensByProvider: [AgentKind: Int] = [:]
    var totalTokens = TokenUsage.zero
    var unknownModelTokens = 0
    var hasUnknownModels = false

    for (key, tokens) in byDayProviderModel {
      guard key.day >= startDate, key.day < endDate else { continue }
      totalTokens += tokens
      tokensByProvider[key.provider, default: .zero] += tokens

      if let unpriced = unpricedTokensByDayProviderModel[key], unpriced > 0 {
        unknownModelTokens += unpriced
        unknownTokensByProvider[key.provider, default: 0] += unpriced
        hasUnknownModels = true
      }
      if let entryCost = costByDayProviderModel[key] {
        totalCost += entryCost
        costByProvider[key.provider, default: 0.0] += entryCost
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
      unknownModelTokens: unknownModelTokens,
      tokensByProvider: tokensByProvider,
      unknownTokensByProvider: unknownTokensByProvider
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
          if let itemCost = costByDayHourProviderModel[key] {
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
          if let itemCost = costByDayProviderModel[key] {
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
