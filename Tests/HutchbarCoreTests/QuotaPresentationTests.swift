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

@Suite("QuotaPresentationTests")
struct QuotaPresentationTests {
  private let baseTime = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0)

  @Test func quotaPresentation_groupingByProvider() {
    let claudeQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "default",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 15.0, resetsAt: baseTime.addingTimeInterval(3600))
      ],
      observedAt: baseTime
    )
    let codexQuota = AccountQuota(
      agent: .codex,
      accountName: "work",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 50.0, resetsAt: baseTime.addingTimeInterval(7200))
      ],
      observedAt: baseTime
    )

    let presentation = QuotaPresentation(
      quotas: [claudeQuota, codexQuota],
      now: baseTime,
      language: .ru
    )

    #expect(presentation.cards.count == 2)
    #expect(presentation.card(for: .claudeCode)?.accounts.first?.name == "default")
    #expect(presentation.card(for: .codex)?.accounts.first?.name == "work")
  }

  @Test func quotaPresentation_remainingPercentAndLevels() {
    #expect(QuotaPresentation.evaluateLevel(for: 50.0) == .normal)
    #expect(QuotaPresentation.evaluateLevel(for: 20.0) == .normal)
    #expect(QuotaPresentation.evaluateLevel(for: 19.9) == .warning)
    #expect(QuotaPresentation.evaluateLevel(for: 10.0) == .warning)
    #expect(QuotaPresentation.evaluateLevel(for: 9.9) == .critical)
    #expect(QuotaPresentation.evaluateLevel(for: 0.0) == .critical)
  }

  @Test func quotaPresentation_paceOnWindowEdges() {
    let windowMinutes = 300
    let windowDuration = TimeInterval(windowMinutes * 60)

    let resetsAtStart = baseTime.addingTimeInterval(windowDuration)
    let paceStart = QuotaPresentation.calculatePace(
      resetsAt: resetsAtStart,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceStart == 0.0)

    let resetsAtMid = baseTime.addingTimeInterval(windowDuration / 2.0)
    let paceMid = QuotaPresentation.calculatePace(
      resetsAt: resetsAtMid,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceMid == 0.5)

    let paceEnd = QuotaPresentation.calculatePace(
      resetsAt: baseTime,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceEnd == 1.0)

    let resetsFuture = baseTime.addingTimeInterval(windowDuration + 1000)
    let paceClampedStart = QuotaPresentation.calculatePace(
      resetsAt: resetsFuture,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceClampedStart == 0.0)

    let resetsPast = baseTime.addingTimeInterval(-100)
    let paceClampedEnd = QuotaPresentation.calculatePace(
      resetsAt: resetsPast,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceClampedEnd == 1.0)

    let paceNil = QuotaPresentation.calculatePace(
      resetsAt: nil,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceNil == nil)
  }

  @Test func quotaPresentation_countdownViaL10n() {
    let freshReset = baseTime.addingTimeInterval((4 * 3600) + (59 * 60))
    let freshWindow = QuotaWindow(
      windowMinutes: 300,
      usedPercent: 20.0,
      resetsAt: freshReset
    )

    let freshPres = QuotaPresentation.makeWindowPresentation(
      window: freshWindow,
      now: baseTime,
      language: .ru
    )
    #expect(freshPres.resetsInText == "4 ч 59 мин")
    #expect(freshPres.remainingText == "Осталось 80 %")
    #expect(freshPres.level == .normal)
    #expect(!freshPres.isStale)
  }

  @Test func quotaPresentation_emptyQuotas() {
    let presentation = QuotaPresentation(quotas: [], now: baseTime)
    #expect(presentation.cards.isEmpty)
    #expect(presentation.card(for: .claudeCode) == nil)
  }

  @Test func quotaPresentation_masonryTwoColumnLayout() {
    let resetDate = baseTime.addingTimeInterval(3600)
    let claudeQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "claude-user",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 10.0, resetsAt: resetDate),
        QuotaWindow(windowMinutes: 10080, usedPercent: 20.0, resetsAt: resetDate),
      ],
      observedAt: baseTime
    )
    let codexQuota = AccountQuota(
      agent: .codex,
      accountName: "codex-user",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 15.0, resetsAt: resetDate),
        QuotaWindow(windowMinutes: 10080, usedPercent: 25.0, resetsAt: resetDate),
        QuotaWindow(windowMinutes: 60, usedPercent: 5.0, resetsAt: resetDate),
        QuotaWindow(windowMinutes: 120, usedPercent: 8.0, resetsAt: resetDate),
      ],
      observedAt: baseTime
    )
    let agyQuota = AccountQuota(
      agent: .antigravity,
      accountName: "agy-user",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 30.0, resetsAt: resetDate),
        QuotaWindow(windowMinutes: 10080, usedPercent: 40.0, resetsAt: resetDate),
      ],
      observedAt: baseTime
    )
    let qwenQuota = AccountQuota(
      agent: .qwen,
      accountName: "qwen-user",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 50.0, resetsAt: resetDate)
      ],
      observedAt: baseTime
    )

    let presentation = QuotaPresentation(
      quotas: [codexQuota, qwenQuota, claudeQuota, agyQuota],
      now: baseTime
    )

    let columns = presentation.cardColumns
    #expect(columns.left.map(\.agent) == [.claudeCode, .antigravity, .qwen])
    #expect(columns.right.map(\.agent) == [.codex])
  }

  @Test func quotaPresentation_scopeGroupingAndOrder() {
    let resetDate = baseTime.addingTimeInterval(3600)
    let windowGeminiWeek = QuotaWindow(
      windowMinutes: 10080, usedPercent: 40.0, resetsAt: resetDate, scope: "Gemini")
    let windowGemini5h = QuotaWindow(
      windowMinutes: 300, usedPercent: 10.0, resetsAt: resetDate, scope: "Gemini")
    let windowClaudeWeek = QuotaWindow(
      windowMinutes: 10080, usedPercent: 30.0, resetsAt: resetDate, scope: "Claude+GPT")
    let windowClaude5h = QuotaWindow(
      windowMinutes: 300, usedPercent: 20.0, resetsAt: resetDate, scope: "Claude+GPT")

    let quota = AccountQuota(
      agent: .antigravity,
      accountName: "work",
      windows: [windowGeminiWeek, windowGemini5h, windowClaudeWeek, windowClaude5h],
      observedAt: baseTime
    )

    let presentation = QuotaPresentation(quotas: [quota], now: baseTime, language: .ru)
    guard let card = presentation.card(for: .antigravity),
      let account = card.accounts.first
    else {
      Issue.record("Card or account missing")
      return
    }

    #expect(account.windowGroups.count == 2)

    let groupClaude = account.windowGroups[0]
    #expect(groupClaude.scope == "Claude+GPT")
    #expect(groupClaude.windows.count == 2)
    #expect(groupClaude.windows[0].windowMinutes == 300)
    #expect(groupClaude.windows[0].label == "Сессия")
    #expect(groupClaude.windows[1].windowMinutes == 10080)
    #expect(groupClaude.windows[1].label == "Неделя")

    let groupGemini = account.windowGroups[1]
    #expect(groupGemini.scope == "Gemini")
    #expect(groupGemini.windows.count == 2)
    #expect(groupGemini.windows[0].windowMinutes == 300)
    #expect(groupGemini.windows[0].label == "Сессия")
    #expect(groupGemini.windows[1].windowMinutes == 10080)
    #expect(groupGemini.windows[1].label == "Неделя")

    #expect(account.windows.count == 4)
  }

  @Test func quotaPresentation_unscopedAndScopedMixed() {
    let resetDate = baseTime.addingTimeInterval(3600)
    let windowUnscopedWeek = QuotaWindow(
      windowMinutes: 10080, usedPercent: 50.0, resetsAt: resetDate, scope: nil)
    let windowUnscoped5h = QuotaWindow(
      windowMinutes: 300, usedPercent: 10.0, resetsAt: resetDate, scope: nil)
    let windowScoped = QuotaWindow(
      windowMinutes: 10080, usedPercent: 20.0, resetsAt: resetDate, scope: "Sonnet")

    let quota = AccountQuota(
      agent: .claudeCode,
      accountName: "mixed",
      windows: [windowUnscopedWeek, windowUnscoped5h, windowScoped],
      observedAt: baseTime
    )

    let presentation = QuotaPresentation(quotas: [quota], now: baseTime, language: .ru)
    guard let account = presentation.card(for: .claudeCode)?.accounts.first else {
      Issue.record("Account missing")
      return
    }

    #expect(account.windowGroups.count == 2)
    let unscopedGroup = account.windowGroups[0]
    #expect(unscopedGroup.scope == nil)
    #expect(unscopedGroup.windows.count == 2)
    #expect(unscopedGroup.windows[0].windowMinutes == 300)
    #expect(unscopedGroup.windows[1].windowMinutes == 10080)

    let scopedGroup = account.windowGroups[1]
    #expect(scopedGroup.scope == "Sonnet")
    #expect(scopedGroup.windows.count == 1)
  }
}
