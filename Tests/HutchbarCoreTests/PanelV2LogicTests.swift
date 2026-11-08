// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

@Suite("PanelV2LogicTests")
struct PanelV2LogicTests {

  @Test func colorSelection_agents() {
    #expect(PanelV2Logic.agentColor(for: .claudeCode) == .orange)
    #expect(PanelV2Logic.agentColor(for: .codex) == .blue)
  }

  @Test func colorSelection_sessionStates() {
    #expect(PanelV2Logic.sessionStateColor(for: .waitingForApproval) == .orange)
    #expect(PanelV2Logic.sessionStateColor(for: .waitingForInput) == .blue)
    #expect(PanelV2Logic.sessionStateColor(for: .running) == .secondary)
    #expect(PanelV2Logic.sessionStateColor(for: .finished) == .secondary)
  }

  @Test func colorSelection_quotaBar() {
    #expect(PanelV2Logic.quotaBarColor(remainingPercent: 50.0, isStale: false) == .green)
    #expect(PanelV2Logic.quotaBarColor(remainingPercent: 20.0, isStale: false) == .green)
    #expect(PanelV2Logic.quotaBarColor(remainingPercent: 19.9, isStale: false) == .orange)
    #expect(PanelV2Logic.quotaBarColor(remainingPercent: 10.0, isStale: false) == .orange)
    #expect(PanelV2Logic.quotaBarColor(remainingPercent: 9.9, isStale: false) == .red)
    #expect(PanelV2Logic.quotaBarColor(remainingPercent: 0.0, isStale: false) == .red)
    #expect(PanelV2Logic.quotaBarColor(remainingPercent: 90.0, isStale: true) == .secondary)
  }

  @Test func sessionSorting_approvalBeforeInputBeforeRunning() {
    let now = Date()
    let s1 = SessionSnapshot(
      id: "run1",
      agent: .claudeCode,
      state: .running,
      projectName: "Proj",
      lastActivity: now
    )
    let s2 = SessionSnapshot(
      id: "input1",
      agent: .codex,
      state: .waitingForInput,
      projectName: "Proj",
      lastActivity: now,
      waitingSince: now.addingTimeInterval(-60)
    )
    let s3 = SessionSnapshot(
      id: "appr1",
      agent: .claudeCode,
      state: .waitingForApproval,
      projectName: "Proj",
      lastActivity: now,
      waitingSince: now.addingTimeInterval(-30)
    )
    let s4 = SessionSnapshot(
      id: "fin1",
      agent: .codex,
      state: .finished,
      projectName: "Proj",
      lastActivity: now
    )

    let sorted = PanelV2Logic.sortSessions([s1, s2, s3, s4])
    #expect(sorted.map(\.id) == ["appr1", "input1", "run1", "fin1"])
  }

  @Test func sessionSorting_waitingTimeLongestFirst() {
    let now = Date()
    let shorter = SessionSnapshot(
      id: "shorter",
      agent: .claudeCode,
      state: .waitingForApproval,
      projectName: "Proj",
      lastActivity: now,
      waitingSince: now.addingTimeInterval(-10)
    )
    let longer = SessionSnapshot(
      id: "longer",
      agent: .claudeCode,
      state: .waitingForApproval,
      projectName: "Proj",
      lastActivity: now,
      waitingSince: now.addingTimeInterval(-100)
    )

    let sorted = PanelV2Logic.sortSessions([shorter, longer])
    #expect(sorted.map(\.id) == ["longer", "shorter"])
  }

  @Test func sessionSorting_runningActivityMostRecentFirst() {
    let now = Date()
    let older = SessionSnapshot(
      id: "older",
      agent: .codex,
      state: .running,
      projectName: "Proj",
      lastActivity: now.addingTimeInterval(-50)
    )
    let newer = SessionSnapshot(
      id: "newer",
      agent: .codex,
      state: .running,
      projectName: "Proj",
      lastActivity: now
    )

    let sorted = PanelV2Logic.sortSessions([older, newer])
    #expect(sorted.map(\.id) == ["newer", "older"])
  }

  @Test func tokenCountFormatting() {
    #expect(PanelV2Logic.formatTokenCount(0) == "0")
    #expect(PanelV2Logic.formatTokenCount(-5) == "0")
    #expect(PanelV2Logic.formatTokenCount(500) == "500")
    #expect(PanelV2Logic.formatTokenCount(1_000) == "1k")
    #expect(PanelV2Logic.formatTokenCount(12_000) == "12k")
    #expect(PanelV2Logic.formatTokenCount(12_400) == "12k")
    #expect(PanelV2Logic.formatTokenCount(1_500) == "1.5k")
    #expect(PanelV2Logic.formatTokenCount(1_000_000) == "1M")
    #expect(PanelV2Logic.formatTokenCount(12_000_000) == "12M")
    #expect(PanelV2Logic.formatTokenCount(12_400_000) == "12M")
    #expect(PanelV2Logic.formatTokenCount(1_500_000) == "1.5M")
  }

  @Test func tokenAndCacheSummary() {
    let summaryRu = PanelV2Logic.formatTokenAndCacheSummary(
      tokens: 12_000_000,
      cachedShare: 0.94,
      language: .ru
    )
    #expect(summaryRu == "12M токенов · кэш 94 %")

    let summaryEn = PanelV2Logic.formatTokenAndCacheSummary(
      tokens: 12_000_000,
      cachedShare: 0.94,
      language: .en
    )
    #expect(summaryEn == "12M tokens · cache 94 %")
  }

  @Test func currencyFormatting() {
    let usLocale = Locale(identifier: "en_US")
    let ruLocale = Locale(identifier: "ru_RU")

    #expect(PanelV2Logic.formatCurrency(amount: 6.54, locale: usLocale) == "$6.54")
    #expect(PanelV2Logic.formatCurrency(amount: 6.54, locale: ruLocale) == "$6,54")
    #expect(PanelV2Logic.formatCurrency(amount: 0.0, locale: usLocale) == "$0.00")
  }
}

extension PanelV2LogicTests {
  @Test func l10n_modelsWithoutPrice() {
    #expect(L10n.modelsWithoutPrice(language: .ru) == "модели без цены")
    #expect(L10n.modelsWithoutPrice(language: .en) == "models without price")
  }

  @Test func trendAxisLabels() {
    let utc = TimeZone(secondsFromGMT: 0) ?? .current
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let p1 = UsagePoint(date: now, costUSD: 1.0)
    let p2 = UsagePoint(date: now.addingTimeInterval(3600), costUSD: 2.0)

    let labels = PanelV2Logic.formatTrendAxisLabels(
      period: .today,
      points: [p1, p2],
      timeZone: utc,
      language: .en
    )
    #expect(!labels.leading.isEmpty)
    #expect(!labels.trailing.isEmpty)
  }

  @Test func panelV2_providerSpendingText_allCostUnknown() {
    let ru = PanelV2Logic.providerSpendingText(
      cost: nil,
      totalTokens: 12_000,
      unknownTokens: 12_000,
      language: .ru
    )
    #expect(ru == "— · 12k токенов")

    let en = PanelV2Logic.providerSpendingText(
      cost: nil,
      totalTokens: 12_000,
      unknownTokens: 12_000,
      language: .en
    )
    #expect(en == "— · 12k tokens")
  }

  @Test func panelV2_providerSpendingText_partiallyUnknown() {
    let ruLocale = Locale(identifier: "ru_RU")
    let usLocale = Locale(identifier: "en_US")

    let ru = PanelV2Logic.providerSpendingText(
      cost: 5.10,
      totalTokens: 50_000,
      unknownTokens: 10_000,
      locale: ruLocale,
      language: .ru
    )
    #expect(ru == "$5,10 + модели без цены")

    let en = PanelV2Logic.providerSpendingText(
      cost: 5.10,
      totalTokens: 50_000,
      unknownTokens: 10_000,
      locale: usLocale,
      language: .en
    )
    #expect(en == "$5.10 + models without price")
  }

  @Test func panelV2_providerSpendingText_fullyKnown() {
    let ruLocale = Locale(identifier: "ru_RU")
    let usLocale = Locale(identifier: "en_US")

    let ru = PanelV2Logic.providerSpendingText(
      cost: 5.10,
      totalTokens: 50_000,
      unknownTokens: 0,
      locale: ruLocale,
      language: .ru
    )
    #expect(ru == "$5,10")

    let en = PanelV2Logic.providerSpendingText(
      cost: 5.10,
      totalTokens: 50_000,
      unknownTokens: 0,
      locale: usLocale,
      language: .en
    )
    #expect(en == "$5.10")
  }

  @Test func panelV2_providerSpendingText_zeroUsage() {
    let usLocale = Locale(identifier: "en_US")
    let text = PanelV2Logic.providerSpendingText(
      cost: nil,
      totalTokens: 0,
      unknownTokens: 0,
      locale: usLocale,
      language: .en
    )
    #expect(text == "$0.00")
  }

  @Test func panelV2_l10n_noPrice() {
    #expect(L10n.noPrice(language: .ru) == "нет цены")
    #expect(L10n.noPrice(language: .en) == "no price")
  }

  @Test func panelV2_trendHourHelpers() {
    #expect(PanelV2Logic.formatHourLabel(hour: 0) == "00:00")
    #expect(PanelV2Logic.formatHourLabel(hour: 9) == "09:00")
    #expect(PanelV2Logic.formatHourLabel(hour: 14) == "14:00")
    #expect(PanelV2Logic.formatHourLabel(hour: 23) == "23:00")

    var calendar = Calendar(identifier: .gregorian)
    guard let utc = TimeZone(secondsFromGMT: 0) else { return }
    calendar.timeZone = utc
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    let hour = PanelV2Logic.currentHourIndex(now: fixedDate, calendar: calendar)
    #expect(hour == 22)
  }

  @Test func panelV2_l10n_interfaceLanguagePreference() {
    L10n.withLanguage(.en) {
      #expect(L10n.currentLanguage() == .en)
    }

    let original = L10n.preference
    defer { L10n.preference = original }

    L10n.preference = .ru
    #expect(L10n.currentLanguage(preferredLanguages: ["en-US"]) == .ru)

    L10n.preference = .en
    #expect(L10n.currentLanguage(preferredLanguages: ["ru-RU"]) == .en)

    L10n.preference = .system
    #expect(L10n.currentLanguage(preferredLanguages: ["ru-RU"]) == .ru)
    #expect(L10n.currentLanguage(preferredLanguages: ["en-RU"]) == .en)
  }
}
