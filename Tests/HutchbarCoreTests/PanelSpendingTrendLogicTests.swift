// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

@Suite("PanelSpendingTrendLogicTests")
struct PanelSpendingTrendLogicTests {

  @Test func panelV2_agentSpendingRows_fullyKnown() {
    let ruLocale = Locale(identifier: "ru_RU")
    let tokens: [AgentKind: TokenUsage] = [
      .claudeCode: TokenUsage(
        input: 61_000_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    ]
    let rows = PanelV2Logic.agentSpendingRows(
      tokensByProvider: tokens,
      costByProvider: [.claudeCode: 28.25],
      unknownTokensByProvider: [.claudeCode: 0],
      locale: ruLocale,
      language: .ru
    )

    #expect(rows.count == 1)
    guard let row = rows.first else { return }
    #expect(row.agent == .claudeCode)
    #expect(row.name == "Claude")
    #expect(row.tokenText == "61M")
    #expect(row.costText == "$28,25")
    #expect(row.costNote == nil)
  }

  @Test func panelV2_agentSpendingRows_fullyUnknown() {
    let ruLocale = Locale(identifier: "ru_RU")
    let tokens: [AgentKind: TokenUsage] = [
      .codex: TokenUsage(
        input: 4_200_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    ]
    let rows = PanelV2Logic.agentSpendingRows(
      tokensByProvider: tokens,
      costByProvider: [:],
      unknownTokensByProvider: [.codex: 4_200_000],
      locale: ruLocale,
      language: .ru
    )

    #expect(rows.count == 1)
    guard let row = rows.first else { return }
    #expect(row.agent == .codex)
    #expect(row.name == "Codex")
    #expect(row.tokenText == "4,2M")
    #expect(row.costText == "—")
    #expect(row.costNote == nil)
  }

  @Test func panelV2_agentSpendingRows_partiallyUnknown() {
    let ruLocale = Locale(identifier: "ru_RU")
    let tokens: [AgentKind: TokenUsage] = [
      .claudeCode: TokenUsage(
        input: 10_000_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0)
    ]
    let rowsRu = PanelV2Logic.agentSpendingRows(
      tokensByProvider: tokens,
      costByProvider: [.claudeCode: 15.50],
      unknownTokensByProvider: [.claudeCode: 2_000_000],
      locale: ruLocale,
      language: .ru
    )
    guard let rowRu = rowsRu.first else { return }
    #expect(rowRu.costText == "$15,50")
    #expect(rowRu.costNote == "+ без цены")

    let rowsEn = PanelV2Logic.agentSpendingRows(
      tokensByProvider: tokens,
      costByProvider: [.claudeCode: 15.50],
      unknownTokensByProvider: [.claudeCode: 2_000_000],
      locale: Locale(identifier: "en_US"),
      language: .en
    )
    guard let rowEn = rowsEn.first else { return }
    #expect(rowEn.costText == "$15.50")
    #expect(rowEn.costNote == "+ without price")
  }

  @Test func panelV2_agentSpendingRows_orderingAndZeroTokensFilter() {
    let tokens: [AgentKind: TokenUsage] = [
      .claudeCode: TokenUsage(
        input: 1_000_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
      .codex: TokenUsage(
        input: 2_000_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
    ]
    let rowsCost = PanelV2Logic.agentSpendingRows(
      tokensByProvider: tokens,
      costByProvider: [.claudeCode: 10.0, .codex: 20.0],
      unknownTokensByProvider: [:]
    )
    #expect(rowsCost.map(\.agent) == [.codex, .claudeCode])

    let rowsTokens = PanelV2Logic.agentSpendingRows(
      tokensByProvider: tokens,
      costByProvider: [.claudeCode: 10.0, .codex: 10.0],
      unknownTokensByProvider: [:]
    )
    #expect(rowsTokens.map(\.agent) == [.codex, .claudeCode])

    let filtered = PanelV2Logic.agentSpendingRows(
      tokensByProvider: [
        .claudeCode: .zero,
        .codex: TokenUsage(input: 500, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
      ],
      costByProvider: [.claudeCode: 5.0, .codex: 1.0],
      unknownTokensByProvider: [:]
    )
    #expect(filtered.map(\.agent) == [.codex])
  }

  @Test func panelV2_formatCacheSummary() {
    #expect(PanelV2Logic.formatCacheSummary(cachedShare: 0.95, language: .ru) == "кэш 95 %")
    #expect(PanelV2Logic.formatCacheSummary(cachedShare: 0.95, language: .en) == "cache 95 %")
    #expect(PanelV2Logic.formatCacheSummary(cachedShare: 0.0, language: .ru) == "кэш 0 %")
  }

  @Test func panelV2_trendAxisLabels_todaySeparated() {
    guard let utc = TimeZone(secondsFromGMT: 0) else { return }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let baseDay = Date(timeIntervalSince1970: 1_700_000_000)
    let startOfDay = calendar.startOfDay(for: baseDay)

    var points: [UsagePoint] = []
    for hour in 0..<24 {
      guard let date = calendar.date(byAdding: .hour, value: hour, to: startOfDay) else { continue }
      points.append(UsagePoint(date: date))
    }

    guard let nowHour14 = calendar.date(byAdding: .hour, value: 14, to: startOfDay) else { return }
    let labels = PanelV2Logic.trendAxisLabels(
      period: .today,
      points: points,
      now: nowHour14,
      calendar: calendar,
      timeZone: utc,
      language: .en
    )
    #expect(labels.leading.text == "00:00")
    #expect(!labels.leading.isCurrent)
    #expect(labels.middle?.text == "14:00")
    #expect(labels.middle?.isCurrent == true)
    #expect(labels.trailing.text == "23:00")
    #expect(!labels.trailing.isCurrent)
  }

  @Test func panelV2_trendAxisLabels_todayNearExtremes() {
    guard let utc = TimeZone(secondsFromGMT: 0) else { return }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    let baseDay = Date(timeIntervalSince1970: 1_700_000_000)
    let startOfDay = calendar.startOfDay(for: baseDay)

    var points: [UsagePoint] = []
    for hour in 0..<24 {
      guard let date = calendar.date(byAdding: .hour, value: hour, to: startOfDay) else { continue }
      points.append(UsagePoint(date: date))
    }

    guard let nowHour1 = calendar.date(byAdding: .hour, value: 1, to: startOfDay) else { return }
    let labelsStart = PanelV2Logic.trendAxisLabels(
      period: .today,
      points: points,
      now: nowHour1,
      calendar: calendar,
      timeZone: utc,
      language: .en
    )
    #expect(labelsStart.leading.text == "01:00")
    #expect(labelsStart.leading.isCurrent)
    #expect(labelsStart.middle == nil)
    #expect(labelsStart.trailing.text == "23:00")

    guard let nowHour22 = calendar.date(byAdding: .hour, value: 22, to: startOfDay) else { return }
    let labelsEnd = PanelV2Logic.trendAxisLabels(
      period: .today,
      points: points,
      now: nowHour22,
      calendar: calendar,
      timeZone: utc,
      language: .en
    )
    #expect(labelsEnd.leading.text == "00:00")
    #expect(!labelsEnd.leading.isCurrent)
    #expect(labelsEnd.middle == nil)
    #expect(labelsEnd.trailing.text == "22:00")
    #expect(labelsEnd.trailing.isCurrent)
  }

  @Test func panelV2_trendAxisLabels_weekShortDays() {
    guard let utc = TimeZone(secondsFromGMT: 0) else { return }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    var components = DateComponents()
    components.year = 2026
    components.month = 11
    components.day = 8
    components.hour = 12
    components.timeZone = utc
    guard let now = calendar.date(from: components) else { return }

    var points: [UsagePoint] = []
    for offset in (0..<7).reversed() {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
      points.append(UsagePoint(date: day))
    }
    #expect(points.count == 7)

    let labelsRu = PanelV2Logic.trendAxisLabels(
      period: .week,
      points: points,
      now: now,
      calendar: calendar,
      timeZone: utc,
      language: .ru
    )
    #expect(labelsRu.leading.text == "пн")
    #expect(!labelsRu.leading.isCurrent)
    #expect(labelsRu.middle == nil)
    #expect(labelsRu.trailing.text == "вс")
    #expect(labelsRu.trailing.isCurrent)

    let day3 = points[3].date
    let labelsSeparated = PanelV2Logic.trendAxisLabels(
      period: .week,
      points: points,
      now: day3,
      calendar: calendar,
      timeZone: utc,
      language: .en
    )
    #expect(labelsSeparated.leading.text == "Mon")
    #expect(labelsSeparated.middle?.text == "Thu")
    #expect(labelsSeparated.middle?.isCurrent == true)
    #expect(labelsSeparated.trailing.text == "Sun")
  }

  @Test func panelV2_trendAxisLabels_monthNumbers() {
    guard let utc = TimeZone(secondsFromGMT: 0) else { return }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    var components = DateComponents()
    components.year = 2026
    components.month = 11
    components.day = 30
    components.hour = 12
    components.timeZone = utc
    guard let now = calendar.date(from: components) else { return }

    var points: [UsagePoint] = []
    for offset in (0..<30).reversed() {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
      points.append(UsagePoint(date: day))
    }
    #expect(points.count == 30)

    let labelsEnd = PanelV2Logic.trendAxisLabels(
      period: .month,
      points: points,
      now: now,
      calendar: calendar,
      timeZone: utc,
      language: .en
    )
    #expect(labelsEnd.leading.text == "1")
    #expect(!labelsEnd.leading.isCurrent)
    #expect(labelsEnd.middle == nil)
    #expect(labelsEnd.trailing.text == "30")
    #expect(labelsEnd.trailing.isCurrent)

    let day15 = points[14].date
    let labelsMiddle = PanelV2Logic.trendAxisLabels(
      period: .month,
      points: points,
      now: day15,
      calendar: calendar,
      timeZone: utc,
      language: .en
    )
    #expect(labelsMiddle.leading.text == "1")
    #expect(labelsMiddle.middle?.text == "15")
    #expect(labelsMiddle.middle?.isCurrent == true)
    #expect(labelsMiddle.trailing.text == "30")
  }

}

extension PanelSpendingTrendLogicTests {
  @Test func panelV2_agentSpendingRows_threeAgentsWithCatalogSymbolsAndPrice() {
    let ruLocale = Locale(identifier: "ru_RU")
    let tokens: [AgentKind: TokenUsage] = [
      .claudeCode: TokenUsage(
        input: 10_000_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
      .codex: TokenUsage(
        input: 5_000_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
      .qwen: TokenUsage(
        input: 2_000_000, output: 0, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0),
      .antigravity: .zero,
    ]
    let costs: [AgentKind: Double] = [
      .claudeCode: 15.0,
      .codex: 8.0,
    ]
    let unknown: [AgentKind: Int] = [
      .claudeCode: 0,
      .codex: 0,
      .qwen: 2_000_000,
    ]

    let rows = PanelV2Logic.agentSpendingRows(
      tokensByProvider: tokens,
      costByProvider: costs,
      unknownTokensByProvider: unknown,
      locale: ruLocale,
      language: .ru
    )

    // Antigravity has 0 tokens -> not shown
    #expect(rows.count == 3)
    #expect(!rows.contains { $0.agent == .antigravity })

    // Claude with price
    guard let claudeRow = rows.first(where: { $0.agent == .claudeCode }) else {
      Issue.record("Claude row missing")
      return
    }
    #expect(claudeRow.name == AgentKind.claudeCode.info.displayName)
    #expect(claudeRow.icon == AgentKind.claudeCode.info.symbol)
    #expect(claudeRow.colorToken == AgentKind.claudeCode.info.color)
    #expect(claudeRow.costText == "$15,00")

    // Codex with price
    guard let codexRow = rows.first(where: { $0.agent == .codex }) else {
      Issue.record("Codex row missing")
      return
    }
    #expect(codexRow.name == AgentKind.codex.info.displayName)
    #expect(codexRow.icon == AgentKind.codex.info.symbol)
    #expect(codexRow.colorToken == AgentKind.codex.info.color)
    #expect(codexRow.costText == "$8,00")

    // Qwen without price -> "—"
    guard let qwenRow = rows.first(where: { $0.agent == .qwen }) else {
      Issue.record("Qwen row missing")
      return
    }
    #expect(qwenRow.name == AgentKind.qwen.info.displayName)
    #expect(qwenRow.icon == AgentKind.qwen.info.symbol)
    #expect(qwenRow.colorToken == AgentKind.qwen.info.color)
    #expect(qwenRow.costText == "—")
    #expect(qwenRow.costNote == nil)
  }
}
