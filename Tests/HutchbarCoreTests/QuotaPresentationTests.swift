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
    #expect(presentation.card(for: .claudeCode)?.primaryAccountName == "default")
    #expect(presentation.card(for: .codex)?.primaryAccountName == "work")
  }

  @Test func quotaPresentation_primaryAccountSelection() {
    let olderObserved = baseTime.addingTimeInterval(-3600)
    let newerObserved = baseTime.addingTimeInterval(-600)

    let accountOne = AccountQuota(
      agent: .claudeCode,
      accountName: "personal",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 10.0, resetsAt: baseTime.addingTimeInterval(3600))
      ],
      observedAt: olderObserved
    )
    let accountTwo = AccountQuota(
      agent: .claudeCode,
      accountName: "work",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 40.0, resetsAt: baseTime.addingTimeInterval(3600))
      ],
      observedAt: newerObserved
    )

    let presentation = QuotaPresentation(
      quotas: [accountOne, accountTwo],
      now: baseTime,
      language: .en
    )

    guard let card = presentation.card(for: .claudeCode) else {
      Issue.record("Claude Code card not found")
      return
    }

    #expect(card.primaryAccountName == "work")
    #expect(card.secondaryAccounts.count == 1)
    #expect(card.secondaryAccounts.first?.accountName == "personal")
  }

  @Test func quotaPresentation_secondaryAccountsSorting() {
    let timeOldest = baseTime.addingTimeInterval(-3000)
    let timeMiddle = baseTime.addingTimeInterval(-2000)
    let timeNewest = baseTime.addingTimeInterval(-1000)

    let quotaNewest = AccountQuota(
      agent: .claudeCode,
      accountName: "primary-acc",
      windows: [],
      observedAt: timeNewest
    )
    let quotaOldest = AccountQuota(
      agent: .claudeCode,
      accountName: "sec-oldest",
      windows: [],
      observedAt: timeOldest
    )
    let quotaMiddle = AccountQuota(
      agent: .claudeCode,
      accountName: "sec-middle",
      windows: [],
      observedAt: timeMiddle
    )

    let presentation = QuotaPresentation(
      quotas: [quotaOldest, quotaNewest, quotaMiddle],
      now: baseTime,
      language: .ru
    )

    guard let card = presentation.card(for: .claudeCode) else {
      Issue.record("Claude Code card not found")
      return
    }

    #expect(card.primaryAccountName == "primary-acc")
    #expect(card.secondaryAccounts.count == 2)
    #expect(card.secondaryAccounts[0].accountName == "sec-middle")
    #expect(card.secondaryAccounts[1].accountName == "sec-oldest")
  }
}

extension QuotaPresentationTests {
  @Test func quotaPresentation_secondaryAccountsCompactString_exhausted() {
    guard let utc = TimeZone(secondsFromGMT: 0) else {
      Issue.record("Failed to create UTC timezone")
      return
    }

    // Saturday 2026-11-07 12:00 -> Monday 2026-11-09 10:00 UTC
    let resetMonday = makeDate(year: 2026, month: 11, day: 9, hour: 10, minute: 0, timeZone: utc)

    let primaryQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "primary",
      windows: [],
      observedAt: baseTime
    )
    let secondaryQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "pro-1",
      windows: [
        QuotaWindow(windowMinutes: 10080, usedPercent: 100.0, resetsAt: resetMonday)
      ],
      observedAt: baseTime.addingTimeInterval(-100)
    )

    let presentationRu = QuotaPresentation(
      quotas: [primaryQuota, secondaryQuota],
      now: baseTime,
      timeZone: utc,
      language: .ru
    )

    let compactRu = presentationRu.card(for: .claudeCode)?.secondaryAccounts.first?.compactString
    #expect(compactRu == "pro-1 · неделя исчерпана · до пн 10:00")

    let presentationEn = QuotaPresentation(
      quotas: [primaryQuota, secondaryQuota],
      now: baseTime,
      timeZone: utc,
      language: .en
    )

    let compactEn = presentationEn.card(for: .claudeCode)?.secondaryAccounts.first?.compactString
    #expect(compactEn == "pro-1 · week used up · until Mon 10:00")
  }

  @Test func quotaPresentation_secondaryAccountsCompactString_remaining() {
    guard let utc = TimeZone(secondsFromGMT: 0) else {
      Issue.record("Failed to create UTC timezone")
      return
    }

    // Resets in 2 days 7 hours = 2 * 86400 + 7 * 3600 = 198000s
    let resetIn2d7h = baseTime.addingTimeInterval(198_000)

    let primaryQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "primary",
      windows: [],
      observedAt: baseTime
    )
    let secondaryQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "pro-1",
      windows: [
        QuotaWindow(windowMinutes: 10080, usedPercent: 63.0, resetsAt: resetIn2d7h)
      ],
      observedAt: baseTime.addingTimeInterval(-100)
    )

    let presentationRu = QuotaPresentation(
      quotas: [primaryQuota, secondaryQuota],
      now: baseTime,
      timeZone: utc,
      language: .ru
    )

    let compactRu = presentationRu.card(for: .claudeCode)?.secondaryAccounts.first?.compactString
    #expect(compactRu == "pro-1 · неделя: осталось 37 % · ↻ 2 д 7 ч")

    let presentationEn = QuotaPresentation(
      quotas: [primaryQuota, secondaryQuota],
      now: baseTime,
      timeZone: utc,
      language: .en
    )

    let compactEn = presentationEn.card(for: .claudeCode)?.secondaryAccounts.first?.compactString
    #expect(compactEn == "pro-1 · week: remaining 37% · ↻ 2d 7h")
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
    let windowDuration = TimeInterval(windowMinutes * 60)  // 18000s = 5 hours

    // Exactly at window start: resetsAt - now == windowLength -> pace = 0.0
    let resetsAtStart = baseTime.addingTimeInterval(windowDuration)
    let paceStart = QuotaPresentation.calculatePace(
      resetsAt: resetsAtStart,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceStart == 0.0)

    // Mid-window: resetsAt - now == windowLength / 2 -> pace = 0.5
    let resetsAtMid = baseTime.addingTimeInterval(windowDuration / 2.0)
    let paceMid = QuotaPresentation.calculatePace(
      resetsAt: resetsAtMid,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceMid == 0.5)

    // Window end: resetsAt - now == 0 -> pace = 1.0
    let paceEnd = QuotaPresentation.calculatePace(
      resetsAt: baseTime,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceEnd == 1.0)

    // Before window start (clock drift / future skew): pace clamped to 0.0
    let resetsFuture = baseTime.addingTimeInterval(windowDuration + 1000)
    let paceClampedStart = QuotaPresentation.calculatePace(
      resetsAt: resetsFuture,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceClampedStart == 0.0)

    // After window end (past reset): pace clamped to 1.0
    let resetsPast = baseTime.addingTimeInterval(-100)
    let paceClampedEnd = QuotaPresentation.calculatePace(
      resetsAt: resetsPast,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceClampedEnd == 1.0)

    // ResetsAt nil: pace is nil
    let paceNil = QuotaPresentation.calculatePace(
      resetsAt: nil,
      windowMinutes: windowMinutes,
      now: baseTime
    )
    #expect(paceNil == nil)
  }

  @Test func quotaPresentation_staleWindows() {
    let windowMinutes = 300
    let windowDuration = TimeInterval(windowMinutes * 60)

    // Fresh window
    let freshWindow = QuotaWindow(
      windowMinutes: windowMinutes,
      usedPercent: 30.0,
      resetsAt: baseTime.addingTimeInterval(3600)
    )
    #expect(
      !QuotaPresentation.isWindowStale(window: freshWindow, observedAt: baseTime, now: baseTime))

    // Past reset
    let pastResetWindow = QuotaWindow(
      windowMinutes: windowMinutes,
      usedPercent: 30.0,
      resetsAt: baseTime.addingTimeInterval(-10)
    )
    #expect(
      QuotaPresentation.isWindowStale(window: pastResetWindow, observedAt: baseTime, now: baseTime))

    // ObservedAt older than window length
    let oldObservedAt = baseTime.addingTimeInterval(-(windowDuration + 1))
    let staleObservedWindow = QuotaWindow(
      windowMinutes: windowMinutes,
      usedPercent: 30.0,
      resetsAt: baseTime.addingTimeInterval(3600)
    )
    #expect(
      QuotaPresentation.isWindowStale(
        window: staleObservedWindow, observedAt: oldObservedAt, now: baseTime))
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
      observedAt: baseTime,
      now: baseTime,
      language: .ru
    )
    #expect(freshPres.resetsInText == "4 ч 59 мин")
    #expect(freshPres.remainingText == "Осталось 80 %")
    #expect(freshPres.level == .normal)
    #expect(!freshPres.isStale)

    // Stale window shows "нет свежих данных"
    let staleWindow = QuotaWindow(
      windowMinutes: 300,
      usedPercent: 20.0,
      resetsAt: baseTime.addingTimeInterval(-60)
    )
    let stalePres = QuotaPresentation.makeWindowPresentation(
      window: staleWindow,
      observedAt: baseTime,
      now: baseTime,
      language: .ru
    )
    #expect(stalePres.resetsInText == "нет свежих данных")
    #expect(stalePres.isStale)
  }

  @Test func quotaPresentation_emptyQuotas() {
    let presentation = QuotaPresentation(quotas: [], now: baseTime)
    #expect(presentation.cards.isEmpty)
    #expect(presentation.card(for: .claudeCode) == nil)
  }
}
