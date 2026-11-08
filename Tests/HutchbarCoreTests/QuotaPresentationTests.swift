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
}
