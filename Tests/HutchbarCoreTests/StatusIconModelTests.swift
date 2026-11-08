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

@Suite("StatusIconModelTests")
struct StatusIconModelTests {
  private let baseTime = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0)

  @Test func statusIconModel_directInitAndPillStyles() {
    let emptyModel = StatusIconModel(
      sessionRemaining: nil,
      weekRemaining: nil,
      waitingCount: 0,
      pillStyle: .none
    )
    #expect(emptyModel.waitingCount == 0)
    #expect(emptyModel.pillStyle == .none)
    #expect(emptyModel.sessionRemaining == nil)
    #expect(emptyModel.weekRemaining == nil)
    #expect(!emptyModel.barIsCritical)

    let sessionInput = SessionSnapshot(
      id: "input-1",
      agent: .claudeCode,
      state: .waitingForInput,
      projectName: "app",
      lastActivity: baseTime
    )
    let modelInput = StatusIconModel(
      quotas: [],
      waitingSessions: [sessionInput],
      now: baseTime
    )
    #expect(modelInput.waitingCount == 1)
    #expect(modelInput.pillStyle == .yourTurn)

    let sessionApproval = SessionSnapshot(
      id: "approval-1",
      agent: .claudeCode,
      state: .waitingForApproval,
      projectName: "app",
      lastActivity: baseTime
    )
    let modelApproval = StatusIconModel(
      quotas: [],
      waitingSessions: [sessionInput, sessionApproval],
      now: baseTime
    )
    #expect(modelApproval.waitingCount == 2)
    #expect(modelApproval.pillStyle == .approval)
  }

  @Test func statusIconModel_criticality() {
    // Both bars >= 10 -> not critical
    let safeModel = StatusIconModel(
      sessionRemaining: 20.0,
      weekRemaining: 10.0,
      waitingCount: 0,
      pillStyle: .none
    )
    #expect(!safeModel.barIsCritical)

    // Session below 10 -> critical
    let criticalSessionModel = StatusIconModel(
      sessionRemaining: 9.9,
      weekRemaining: 50.0,
      waitingCount: 0,
      pillStyle: .none
    )
    #expect(criticalSessionModel.barIsCritical)

    // Week below 10 -> critical
    let criticalWeekModel = StatusIconModel(
      sessionRemaining: 80.0,
      weekRemaining: 5.0,
      waitingCount: 0,
      pillStyle: .none
    )
    #expect(criticalWeekModel.barIsCritical)

    // nil remaining -> not critical
    let nilModel = StatusIconModel(
      sessionRemaining: nil,
      weekRemaining: nil,
      waitingCount: 0,
      pillStyle: .none
    )
    #expect(!nilModel.barIsCritical)
  }

  @Test func statusIconModel_mostConstrainedAccount() {
    let resetTime = baseTime.addingTimeInterval(3600)

    let accountOne = AccountQuota(
      agent: .claudeCode,
      accountName: "acc-1",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 40.0, resetsAt: resetTime),
        QuotaWindow(windowMinutes: 10080, usedPercent: 20.0, resetsAt: resetTime),
      ],
      observedAt: baseTime
    )
    let accountTwo = AccountQuota(
      agent: .claudeCode,
      accountName: "acc-2",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 75.0, resetsAt: resetTime),
        QuotaWindow(windowMinutes: 10080, usedPercent: 92.0, resetsAt: resetTime),
      ],
      observedAt: baseTime
    )

    let model = StatusIconModel(
      quotas: [accountOne, accountTwo],
      waitingSessions: [],
      now: baseTime
    )

    // 300m window: remaining 60% vs 25% -> most constrained is 25%
    #expect(model.sessionRemaining == 25.0)

    // 10080m window: remaining 80% vs 8% -> most constrained is 8%
    #expect(model.weekRemaining == 8.0)
    #expect(model.barIsCritical)
  }

  @Test func statusIconModel_staleWindowsIgnored() {
    let freshReset = baseTime.addingTimeInterval(3600)
    let pastReset = baseTime.addingTimeInterval(-60)

    // Account with stale reset time has 99% used (1% remaining), but is stale
    let staleResetAccount = AccountQuota(
      agent: .claudeCode,
      accountName: "stale-reset",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 99.0, resetsAt: pastReset)
      ],
      observedAt: baseTime
    )

    // Account with old observedAt has 95% used (5% remaining), but is stale (age > 300 min = 18000s)
    let staleObservedAccount = AccountQuota(
      agent: .claudeCode,
      accountName: "stale-observed",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 95.0, resetsAt: freshReset)
      ],
      observedAt: baseTime.addingTimeInterval(-18001)
    )

    // Fresh account with 30% used (70% remaining)
    let freshAccount = AccountQuota(
      agent: .claudeCode,
      accountName: "fresh-acc",
      windows: [
        QuotaWindow(windowMinutes: 300, usedPercent: 30.0, resetsAt: freshReset)
      ],
      observedAt: baseTime
    )

    let model = StatusIconModel(
      quotas: [staleResetAccount, staleObservedAccount, freshAccount],
      waitingSessions: [],
      now: baseTime
    )

    // Stale accounts should be ignored; only freshAccount (70% remaining) counts
    #expect(model.sessionRemaining == 70.0)
    #expect(!model.barIsCritical)
  }

  @Test func statusIconModel_allStaleWindowsResultInNil() {
    let staleAccount = AccountQuota(
      agent: .claudeCode,
      accountName: "stale-only",
      windows: [
        QuotaWindow(
          windowMinutes: 300, usedPercent: 80.0, resetsAt: baseTime.addingTimeInterval(-100))
      ],
      observedAt: baseTime
    )

    let model = StatusIconModel(
      quotas: [staleAccount],
      waitingSessions: [],
      now: baseTime
    )

    #expect(model.sessionRemaining == nil)
    #expect(model.weekRemaining == nil)
    #expect(!model.barIsCritical)
  }

  @Test func statusIconModel_paceOnWindowEdges() {
    let windowDuration: TimeInterval = 300 * 60

    // Window start
    let paceStart = QuotaPresentation.calculatePace(
      resetsAt: baseTime.addingTimeInterval(windowDuration),
      windowMinutes: 300,
      now: baseTime
    )
    #expect(paceStart == 0.0)

    // Window middle
    let paceMid = QuotaPresentation.calculatePace(
      resetsAt: baseTime.addingTimeInterval(windowDuration / 2),
      windowMinutes: 300,
      now: baseTime
    )
    #expect(paceMid == 0.5)

    // Window end
    let paceEnd = QuotaPresentation.calculatePace(
      resetsAt: baseTime,
      windowMinutes: 300,
      now: baseTime
    )
    #expect(paceEnd == 1.0)
  }

  @Test func statusIconModel_primaryAndSecondaryAccounts() {
    let timeEarlier = baseTime.addingTimeInterval(-1000)
    let timeLater = baseTime.addingTimeInterval(-100)

    let earlierQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "secondary-alpha",
      windows: [],
      observedAt: timeEarlier
    )
    let laterQuota = AccountQuota(
      agent: .claudeCode,
      accountName: "primary-beta",
      windows: [],
      observedAt: timeLater
    )

    let presentation = QuotaPresentation(
      quotas: [earlierQuota, laterQuota],
      now: baseTime,
      language: .ru
    )

    guard let card = presentation.card(for: .claudeCode) else {
      Issue.record("Card missing")
      return
    }

    #expect(card.primaryAccountName == "primary-beta")
    #expect(card.secondaryAccounts.count == 1)
    #expect(card.secondaryAccounts.first?.accountName == "secondary-alpha")
  }

  @Test func statusIconModel_legacyCompatibility() {
    let modelNoWaiting = StatusIconModel(waitingCount: 0, quotaPercent: nil)
    #expect(modelNoWaiting.text == nil)
    #expect(modelNoWaiting.ringPercent == nil)
    #expect(modelNoWaiting.ringLevel == .normal)

    let modelWithWaiting = StatusIconModel(waitingCount: 3, quotaPercent: 85.0)
    #expect(modelWithWaiting.text == "3")
    #expect(modelWithWaiting.ringPercent == 85.0)
    #expect(modelWithWaiting.ringLevel == .warning)

    let modelCritical = StatusIconModel(waitingCount: 1, quotaPercent: 96.0)
    #expect(modelCritical.text == "1")
    #expect(modelCritical.ringPercent == 96.0)
    #expect(modelCritical.ringLevel == .critical)

    #expect(StatusIconModel.evaluateRingLevel(nil) == .normal)
    #expect(StatusIconModel.evaluateRingLevel(50.0) == .normal)
    #expect(StatusIconModel.evaluateRingLevel(80.0) == .warning)
    #expect(StatusIconModel.evaluateRingLevel(95.0) == .critical)
  }
}
