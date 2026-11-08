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

private let testBaseTime = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0)

@Test func panelFormatting_waitingTime_nilAndPastBounds() {
  #expect(formatWaitingTime(since: nil, now: testBaseTime) == "")

  // Less than 60 seconds
  let fortySecondsAgo = testBaseTime.addingTimeInterval(-40)
  #expect(formatWaitingTime(since: fortySecondsAgo, now: testBaseTime) == "just now")

  // Exact 0 or future date
  #expect(formatWaitingTime(since: testBaseTime, now: testBaseTime) == "just now")
  let future = testBaseTime.addingTimeInterval(10)
  #expect(formatWaitingTime(since: future, now: testBaseTime) == "just now")
}

@Test func panelFormatting_waitingTime_minutes() {
  let oneMinuteAgo = testBaseTime.addingTimeInterval(-60)
  #expect(formatWaitingTime(since: oneMinuteAgo, now: testBaseTime) == "1 min")

  let fourMinutesAgo = testBaseTime.addingTimeInterval(-240)
  #expect(formatWaitingTime(since: fourMinutesAgo, now: testBaseTime) == "4 min")

  let fiftyNineMinutesAgo = testBaseTime.addingTimeInterval(-59 * 60)
  #expect(formatWaitingTime(since: fiftyNineMinutesAgo, now: testBaseTime) == "59 min")
}

@Test func panelFormatting_waitingTime_hoursAndDays() {
  let exactlyOneHourAgo = testBaseTime.addingTimeInterval(-3600)
  #expect(formatWaitingTime(since: exactlyOneHourAgo, now: testBaseTime) == "1h")

  let oneHourThirtyAgo = testBaseTime.addingTimeInterval(-5400)
  #expect(formatWaitingTime(since: oneHourThirtyAgo, now: testBaseTime) == "1h 30m")

  let twoDaysAgo = testBaseTime.addingTimeInterval(-2 * 86400)
  #expect(formatWaitingTime(since: twoDaysAgo, now: testBaseTime) == "2d")
}

@Test func panelFormatting_pillDuration() {
  #expect(formatPillDuration(since: nil, now: testBaseTime) == "")

  let zeroAgo = testBaseTime
  #expect(formatPillDuration(since: zeroAgo, now: testBaseTime) == "0m")

  let twoMinutesAgo = testBaseTime.addingTimeInterval(-120)
  #expect(formatPillDuration(since: twoMinutesAgo, now: testBaseTime) == "2m")

  let oneHourAgo = testBaseTime.addingTimeInterval(-3600)
  #expect(formatPillDuration(since: oneHourAgo, now: testBaseTime) == "1h")

  let oneHourTenAgo = testBaseTime.addingTimeInterval(-4200)
  #expect(formatPillDuration(since: oneHourTenAgo, now: testBaseTime) == "1h 10m")

  let threeDaysAgo = testBaseTime.addingTimeInterval(-3 * 86400)
  #expect(formatPillDuration(since: threeDaysAgo, now: testBaseTime) == "3d")
}

@Test func panelFormatting_percent() {
  #expect(formatPercent(0.0) == "0%")
  #expect(formatPercent(50.0) == "50%")
  #expect(formatPercent(85.0) == "85%")
  #expect(formatPercent(25.5) == "25.5%")
  #expect(formatPercent(100.0) == "100%")

  // Clamping
  #expect(formatPercent(-10.0) == "0%")
  #expect(formatPercent(120.0) == "100%")
}

@Test func panelFormatting_quotaReset_nil() {
  #expect(formatQuotaReset(resetsAt: nil, now: testBaseTime) == nil)
}

@Test func panelFormatting_quotaReset_today() throws {
  guard let utc = TimeZone(secondsFromGMT: 0) else {
    Issue.record("Failed to create UTC timezone")
    return
  }
  let now = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0, timeZone: utc)
  let resetSameDay = makeDate(year: 2026, month: 11, day: 7, hour: 21, minute: 30, timeZone: utc)

  let formatted = formatQuotaReset(
    resetsAt: resetSameDay,
    now: now,
    timeZone: utc
  )
  #expect(formatted == "↻ 21:30")
}

@Test func panelFormatting_quotaReset_laterDay() throws {
  guard let utc = TimeZone(secondsFromGMT: 0) else {
    Issue.record("Failed to create UTC timezone")
    return
  }
  // Saturday 2026-11-07 -> Wednesday 2026-11-11
  let now = makeDate(year: 2026, month: 11, day: 7, hour: 12, minute: 0, timeZone: utc)
  let resetLaterDay = makeDate(year: 2026, month: 11, day: 11, hour: 14, minute: 0, timeZone: utc)

  let formatted = formatQuotaReset(
    resetsAt: resetLaterDay,
    now: now,
    timeZone: utc
  )
  #expect(formatted == "↻ Wed")
}

@Test func panelFormatting_quotaReset_timeZoneAwareness() throws {
  guard let utc = TimeZone(secondsFromGMT: 0),
    let newYork = TimeZone(secondsFromGMT: -5 * 3600)
  else {
    Issue.record("Failed to create timezones")
    return
  }

  // Saturday 14:00 UTC
  let now = makeDate(year: 2026, month: 11, day: 7, hour: 14, minute: 0, timeZone: utc)
  // Sunday 02:00 UTC (which is Saturday 21:00 in New York, UTC-5)
  let resetsAt = makeDate(year: 2026, month: 11, day: 8, hour: 2, minute: 0, timeZone: utc)

  // In UTC: Saturday -> Sunday (different days) -> "↻ Sun"
  let inUtc = formatQuotaReset(resetsAt: resetsAt, now: now, timeZone: utc)
  #expect(inUtc == "↻ Sun")

  // In New York: Saturday 09:00 -> Saturday 21:00 (same day) -> "↻ 21:00"
  let inNewYork = formatQuotaReset(resetsAt: resetsAt, now: now, timeZone: newYork)
  #expect(inNewYork == "↻ 21:00")
}

@Test func panelFormatting_sessionStateDescription() {
  #expect(sessionStateDescription(.waitingForApproval) == "waiting for approval")
  #expect(sessionStateDescription(.waitingForInput) == "waiting for input")
  #expect(sessionStateDescription(.running) == "running")
  #expect(sessionStateDescription(.finished) == "finished")
}

@Test func panelFormatting_quotaWindowDuration() {
  #expect(formatQuotaWindowDuration(300) == "5h")
  #expect(formatQuotaWindowDuration(10080) == "7d")
  #expect(formatQuotaWindowDuration(60) == "1h")
  #expect(formatQuotaWindowDuration(120) == "2h")
  #expect(formatQuotaWindowDuration(45) == "45m")
}
