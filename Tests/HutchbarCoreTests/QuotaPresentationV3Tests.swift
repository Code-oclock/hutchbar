// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func makeDate(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current
) -> Date {
  var components = DateComponents()
  components.year = year
  components.month = month
  components.day = day
  components.hour = hour
  components.minute = minute
  components.second = 0
  components.timeZone = timeZone

  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = timeZone
  return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

@Suite("QuotaPresentationV3Tests")
struct QuotaPresentationV3Tests {
  private let baseTime = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0)

  /// A gateway cannot tell which subscription its alias is: never merged with direct accounts,
  /// shown in its own group even when the weeks reset together.
  @Test func quotaPresentationV3_ccrStaysApartFromCliAccount() {
    let resetTime = baseTime.addingTimeInterval(86400 * 3)
    let ccrQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "pro-1",
      windows: [
        QuotaWindow(windowMinutes: 10080, usedPercent: 40.0, resetsAt: resetTime)
      ],
      observedAt: baseTime.addingTimeInterval(-100),
      source: .ccr
    )
    let cliQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "john",
      windows: [
        QuotaWindow(
          windowMinutes: 10080, usedPercent: 60.0, resetsAt: resetTime.addingTimeInterval(30))
      ],
      observedAt: baseTime,
      source: .agentCLI
    )

    let presentation = QuotaPresentation(
      quotas: [ccrQuota, cliQuota], now: baseTime, language: .ru)
    guard let card = presentation.card(for: .claudeCode) else {
      Issue.record("Card not found")
      return
    }

    #expect(card.accounts.map(\.name) == ["john"])
    #expect(card.accounts[0].windows.first?.remainingPercent == 40.0)
    #expect(card.gateways.map(\.name) == ["ccr"])
    let gatewayAccount = card.gateways.first?.accounts.first
    #expect(gatewayAccount?.name == "pro-1")
    #expect(gatewayAccount?.windows.first?.remainingPercent == 60.0)
    // The gateway alias was used last: it is "now", the direct account is not guessed.
    #expect(gatewayAccount?.isCurrent == true)
    #expect(card.accounts[0].isCurrent == false)
  }

  @Test func quotaPresentationV3_codexLogPlusAndCliMerge() {
    let resetTime = baseTime.addingTimeInterval(86400 * 2)
    let logQuota = AccountQuota(
      agent: .codex,
      accountName: "plus",
      windows: [
        QuotaWindow(windowMinutes: 10080, usedPercent: 10.0, resetsAt: resetTime)
      ],
      observedAt: baseTime.addingTimeInterval(-200),
      source: .sessionLog
    )
    let cliQuota = AccountQuota(
      agent: .codex,
      accountName: "dev-user",
      windows: [
        QuotaWindow(windowMinutes: 10080, usedPercent: 15.0, resetsAt: resetTime)
      ],
      observedAt: baseTime,
      source: .agentCLI
    )

    let presentation = QuotaPresentation(
      quotas: [logQuota, cliQuota], now: baseTime, language: .en)
    guard let card = presentation.card(for: .codex) else {
      Issue.record("Card not found")
      return
    }

    #expect(card.accounts.count == 1)
    #expect(card.accounts[0].name == "dev-user")
  }

  @Test func quotaPresentationV3_gatewayAliasesNeverMerge() {
    let resetTimeA = baseTime.addingTimeInterval(86400 * 2)
    let resetTimeB = resetTimeA.addingTimeInterval(30)
    let quotaA = AccountQuota(
      agent: .claudeCode,
      accountName: "pro-1",
      windows: [
        QuotaWindow(windowMinutes: 10080, usedPercent: 20.0, resetsAt: resetTimeA)
      ],
      observedAt: baseTime,
      source: .ccr
    )
    let quotaB = AccountQuota(
      agent: .claudeCode,
      accountName: "pro-2",
      windows: [
        QuotaWindow(windowMinutes: 10080, usedPercent: 30.0, resetsAt: resetTimeB)
      ],
      observedAt: baseTime,
      source: .ccr
    )

    let presentation = QuotaPresentation(quotas: [quotaA, quotaB], now: baseTime, language: .ru)
    guard let card = presentation.card(for: .claudeCode) else {
      Issue.record("Card not found")
      return
    }

    // A card with gateway accounts only still shows up; resets 30 s apart do not merge aliases.
    #expect(card.accounts.isEmpty)
    #expect(card.gateways.first?.accounts.map(\.name).sorted() == ["pro-1", "pro-2"])
  }

  @Test func quotaPresentationV3_currentAccountBySessionLogOrCcr() {
    let accPolled = AccountQuota(
      agent: .claudeCode,
      accountName: "acc-polled",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 5.0, resetsAt: baseTime.addingTimeInterval(3600))
      ],
      observedAt: baseTime,
      source: .agentCLI
    )
    let accActive = AccountQuota(
      agent: .claudeCode,
      accountName: "acc-active",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 50.0, resetsAt: baseTime.addingTimeInterval(3600))
      ],
      observedAt: baseTime.addingTimeInterval(-300),
      source: .sessionLog
    )

    let presentation = QuotaPresentation(
      quotas: [accPolled, accActive], now: baseTime, language: .ru)
    guard let card = presentation.card(for: .claudeCode) else {
      Issue.record("Card not found")
      return
    }

    #expect(card.accounts.count == 2)
    #expect(card.accounts[0].name == "acc-active")
    #expect(card.accounts[0].isCurrent == true)
    #expect(card.accounts[1].name == "acc-polled")
    #expect(card.accounts[1].isCurrent == false)
  }

  @Test func quotaPresentationV3_restartedWindowInPast() {
    let pastReset = baseTime.addingTimeInterval(-60)
    let window = QuotaWindow(
      windowMinutes: 300,
      usedPercent: 80.0,
      resetsAt: pastReset
    )

    let presRu = QuotaPresentation.makeWindowPresentation(
      window: window, now: baseTime, language: .ru)
    #expect(presRu.remainingPercent == 100.0)
    #expect(presRu.resetsInText == "сброшено")
    #expect(!presRu.isStale)
    #expect(presRu.pace == nil)
    #expect(presRu.level == .normal)

    let presEn = QuotaPresentation.makeWindowPresentation(
      window: window, now: baseTime, language: .en)
    #expect(presEn.remainingPercent == 100.0)
    #expect(presEn.resetsInText == "reset")
    #expect(!presEn.isStale)
    #expect(presEn.pace == nil)
    #expect(presEn.level == .normal)
  }

  @Test func quotaPresentationV3_notStartedWindowCodex() {
    let resetIn5h = baseTime.addingTimeInterval(300 * 60)
    let window = QuotaWindow(
      windowMinutes: 300,
      usedPercent: 0.0,
      resetsAt: resetIn5h
    )

    let presRu = QuotaPresentation.makeWindowPresentation(
      window: window, now: baseTime, language: .ru)
    #expect(presRu.remainingPercent == 100.0)
    #expect(presRu.resetsInText == "не начато")
    #expect(presRu.pace == nil)
    #expect(!presRu.isStale)

    let presEn = QuotaPresentation.makeWindowPresentation(
      window: window, now: baseTime, language: .en)
    #expect(presEn.remainingPercent == 100.0)
    #expect(presEn.resetsInText == "not started")
    #expect(presEn.pace == nil)
    #expect(!presEn.isStale)
  }

  @Test func quotaPresentationV3_scopeInLabelAndOrder() {
    let wOpus = QuotaWindow(
      windowMinutes: 10080,
      usedPercent: 20.0,
      resetsAt: baseTime.addingTimeInterval(3600),
      scope: "Opus"
    )
    let wSession = QuotaWindow(
      windowMinutes: 300,
      usedPercent: 10.0,
      resetsAt: baseTime.addingTimeInterval(3600),
      scope: nil
    )
    let wWeek = QuotaWindow(
      windowMinutes: 10080,
      usedPercent: 30.0,
      resetsAt: baseTime.addingTimeInterval(3600),
      scope: nil
    )
    let quota = AccountQuota(
      agent: .claudeCode,
      accountName: "default",
      windows: [wOpus, wSession, wWeek],
      observedAt: baseTime
    )

    let presentationRu = QuotaPresentation(quotas: [quota], now: baseTime, language: .ru)
    guard let cardRu = presentationRu.card(for: .claudeCode),
      let accountRu = cardRu.accounts.first
    else {
      Issue.record("Card or account not found")
      return
    }

    #expect(accountRu.windows.count == 3)
    #expect(accountRu.windows[0].label == "Сессия")
    #expect(accountRu.windows[1].label == "Неделя")
    #expect(accountRu.windows[2].label == "Неделя · Opus")

    let presentationEn = QuotaPresentation(quotas: [quota], now: baseTime, language: .en)
    guard let cardEn = presentationEn.card(for: .claudeCode),
      let accountEn = cardEn.accounts.first
    else {
      Issue.record("Card or account not found")
      return
    }

    #expect(accountEn.windows[0].label == "Session")
    #expect(accountEn.windows[1].label == "Week")
    #expect(accountEn.windows[2].label == "Week · Opus")
  }

  @Test func quotaPresentationV3_staleRecordShowsAsOf() {
    guard let utc = TimeZone(secondsFromGMT: 0) else {
      Issue.record("Failed to create UTC timezone")
      return
    }
    let observedTime = makeDate(year: 2026, month: 11, day: 7, hour: 14, minute: 20, timeZone: utc)
    let currentTime = makeDate(year: 2026, month: 11, day: 7, hour: 17, minute: 0, timeZone: utc)

    let staleQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "stale-account",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 45.0, resetsAt: currentTime.addingTimeInterval(3600))
      ],
      observedAt: observedTime,
      source: .sessionLog
    )

    let presRu = QuotaPresentation(
      quotas: [staleQuota], now: currentTime, timeZone: utc, language: .ru)
    let accRu = presRu.card(for: .claudeCode)?.accounts.first
    #expect(accRu?.asOfText == "данные от 14:20")
    #expect(accRu?.isStale == true)
    #expect(accRu?.windows.first?.remainingPercent == 55.0)

    let presEn = QuotaPresentation(
      quotas: [staleQuota], now: currentTime, timeZone: utc, language: .en)
    let accEn = presEn.card(for: .claudeCode)?.accounts.first
    #expect(accEn?.asOfText == "as of 14:20")
    #expect(accEn?.isStale == true)

    let cliQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "cli-account",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 45.0, resetsAt: currentTime.addingTimeInterval(3600))
      ],
      observedAt: observedTime,
      source: .agentCLI
    )
    let cliPres = QuotaPresentation(
      quotas: [cliQuota], now: currentTime, timeZone: utc, language: .ru)
    let cliAcc = cliPres.card(for: .claudeCode)?.accounts.first
    #expect(cliAcc?.asOfText == nil)
    #expect(cliAcc?.isStale == false)
  }

}

extension QuotaPresentationV3Tests {
  @Test func quotaPresentationV3_resetCreditsGrammarForms() {
    #expect(L10n.resetCredits(1, language: .ru) == "1 сброс")
    #expect(L10n.resetCredits(2, language: .ru) == "2 сброса")
    #expect(L10n.resetCredits(3, language: .ru) == "3 сброса")
    #expect(L10n.resetCredits(4, language: .ru) == "4 сброса")
    #expect(L10n.resetCredits(5, language: .ru) == "5 сбросов")
    #expect(L10n.resetCredits(11, language: .ru) == "11 сбросов")
    #expect(L10n.resetCredits(12, language: .ru) == "12 сбросов")
    #expect(L10n.resetCredits(21, language: .ru) == "21 сброс")
    #expect(L10n.resetCredits(22, language: .ru) == "22 сброса")
    #expect(L10n.resetCredits(25, language: .ru) == "25 сбросов")

    #expect(L10n.resetCredits(1, language: .en) == "1 reset")
    #expect(L10n.resetCredits(2, language: .en) == "2 resets")
    #expect(L10n.resetCredits(5, language: .en) == "5 resets")

    let quotaZero = AccountQuota(
      agent: .codex,
      accountName: "zero",
      windows: [],
      observedAt: baseTime,
      resetCredits: 0
    )
    let presZero = QuotaPresentation(quotas: [quotaZero], now: baseTime, language: .ru)
    #expect(presZero.card(for: .codex)?.accounts.first?.resetCreditsText == nil)

    let quotaThree = AccountQuota(
      agent: .codex,
      accountName: "three",
      windows: [],
      observedAt: baseTime,
      resetCredits: 3
    )
    let presThree = QuotaPresentation(quotas: [quotaThree], now: baseTime, language: .ru)
    #expect(presThree.card(for: .codex)?.accounts.first?.resetCreditsText == "3 сброса")
  }

  @Test func quotaPresentationV3_planBadgeCapitalization() {
    #expect(QuotaPresentation.formatPlanBadge("pro") == "Pro")
    #expect(QuotaPresentation.formatPlanBadge("plus") == "Plus")
    #expect(QuotaPresentation.formatPlanBadge("max") == "Max")
    #expect(QuotaPresentation.formatPlanBadge("Pro") == "Pro")
    #expect(QuotaPresentation.formatPlanBadge("") == "")

    let quotaPro = AccountQuota(
      agent: .claudeCode,
      accountName: "user",
      windows: [],
      observedAt: baseTime,
      plan: "pro"
    )
    let presPro = QuotaPresentation(quotas: [quotaPro], now: baseTime, language: .en)
    #expect(presPro.card(for: .claudeCode)?.accounts.first?.planBadge == "Pro")
  }
}
