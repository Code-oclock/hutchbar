// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

@Test func usageRecord_messageIdDeduplicated() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

  let line1 = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-001","model":"claude-opus-5-5",\
    "usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10}}}
    """
  let line2 = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:01Z",\
    "message":{"id":"msg-001","model":"claude-opus-5-5",\
    "usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10}}}
    """
  let line3 = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:02Z",\
    "message":{"id":"msg-001","model":"claude-opus-5-5",\
    "usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":10}}}
    """

  var seen = Set<String>()
  let events = parseClaudeUsage(
    lines: [line1, line2, line3], seenMessageIds: &seen, calendar: calendar)

  #expect(events.count == 1)
  let event = try #require(events.first)
  #expect(event.provider == .claudeCode)
  #expect(event.model == "claude-opus-5-5")
  #expect(event.tokens.input == 100)
  #expect(event.tokens.output == 50)
  #expect(event.tokens.cacheRead == 10)
  #expect(seen.contains("msg-001"))
}

@Test func usageRecord_syntheticSkipped() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

  let line = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-synth-01","model":"<synthetic>",\
    "usage":{"input_tokens":500,"output_tokens":200}}}
    """

  var seen = Set<String>()
  let events = parseClaudeUsage(lines: [line], seenMessageIds: &seen, calendar: calendar)

  #expect(events.isEmpty)
}

@Test func usageRecord_5m1hSplitAndFallback() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

  let splitLine = """
    {"type":"assistant","timestamp":"2026-11-08T10:00:00Z",\
    "message":{"id":"msg-split","model":"claude-sonnet-5-5",\
    "usage":{"input_tokens":1000,"output_tokens":200,\
    "cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":150},\
    "cache_read_input_tokens":400}}}
    """
  let fallbackLine = """
    {"type":"assistant","timestamp":"2026-11-08T10:05:00Z",\
    "message":{"id":"msg-fallback","model":"claude-sonnet-5-5",\
    "usage":{"input_tokens":1000,"output_tokens":200,\
    "cache_creation_input_tokens":250,\
    "cache_read_input_tokens":400}}}
    """

  var seen = Set<String>()
  let events = parseClaudeUsage(
    lines: [splitLine, fallbackLine],
    seenMessageIds: &seen,
    calendar: calendar
  )

  #expect(events.count == 2)
  let first = try #require(events.first)
  #expect(first.tokens.cacheWrite5m == 300)
  #expect(first.tokens.cacheWrite1h == 150)
  #expect(first.tokens.cacheRead == 400)

  let second = events[1]
  #expect(second.tokens.cacheWrite5m == 250)
  #expect(second.tokens.cacheWrite1h == 0)
  #expect(second.tokens.cacheRead == 400)
}

@Test func usageRecord_codexLastTokenUsageAndDeltas() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

  let lines = [
    """
    {"type":"turn_context","timestamp":"2026-11-08T12:00:00Z",\
    "payload":{"turn_context":{"model":"claude-opus-5-5"}}}
    """,
    """
    {"type":"event_msg","timestamp":"2026-11-08T12:01:00Z",\
    "payload":{"type":"token_count","info":{"last_token_usage":\
    {"input_tokens":120,"cached_input_tokens":60,"output_tokens":30}}}}
    """,
    """
    {"type":"event_msg","timestamp":"2026-11-08T12:02:00Z",\
    "payload":{"type":"token_count","info":{"total_token_usage":\
    {"input_tokens":300,"cached_input_tokens":100,"output_tokens":80}}}}
    """,
    """
    {"type":"event_msg","timestamp":"2026-11-08T12:03:00Z",\
    "payload":{"type":"token_count","info":{"total_token_usage":\
    {"input_tokens":550,"cached_input_tokens":170,"output_tokens":150}}}}
    """,
  ]

  var state = CodexUsageState()
  let events = parseCodexUsage(lines: lines, state: &state, calendar: calendar)

  #expect(events.count == 3)
  #expect(events[0].model == "claude-opus-5-5")
  #expect(events[0].tokens.input == 120)
  #expect(events[0].tokens.cacheRead == 60)
  #expect(events[0].tokens.output == 30)

  #expect(events[1].model == "claude-opus-5-5")
  #expect(events[1].tokens.input == 300)
  #expect(events[1].tokens.cacheRead == 100)
  #expect(events[1].tokens.output == 80)

  #expect(events[2].model == "claude-opus-5-5")
  #expect(events[2].tokens.input == 250)
  #expect(events[2].tokens.cacheRead == 70)
  #expect(events[2].tokens.output == 70)
}

@Test func usageLedger_unknownModelAccounting() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

  var ledger = UsageLedger()
  ledger.record(
    UsageEvent(
      provider: .claudeCode,
      model: "future-unknown-model",
      day: day,
      hour: 10,
      tokens: TokenUsage(input: 800, output: 200, cacheWrite5m: 50, cacheWrite1h: 0, cacheRead: 150)
    )
  )

  let summary = ledger.summary(
    period: .today,
    now: Date(timeIntervalSince1970: 1_700_000_000),
    calendar: calendar
  )

  #expect(summary.hasUnknownModels)
  #expect(summary.unknownModelTokens == 1200)
  #expect(summary.costUSD == 0.0)
  #expect(summary.tokens.total == 1200)
}

@Test func usageLedger_costForClaudeOpus55ManualCalculation() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let day = calendar.startOfDay(for: date)

  let tokens = TokenUsage(
    input: 1_000_000,
    output: 100_000,
    cacheWrite5m: 400_000,
    cacheWrite1h: 100_000,
    cacheRead: 2_000_000
  )

  // Pricing from ModelPrices:
  // input: 4.0, output: 20.0, cacheRead: 0.20
  // cacheWrite5m = 4.0 * 1.25 = 5.0
  // cacheWrite1h = 4.0 * 2.0 = 8.0
  // Manual expected:
  // 1_000_000 * 4.0 / 1M = 4.00
  // 100_000 * 20.0 / 1M = 2.00
  // 400_000 * 5.0 / 1M = 2.00
  // 100_000 * 8.0 / 1M = 0.80
  // 2_000_000 * 0.20 / 1M = 0.40
  // Total = 4.00 + 2.00 + 2.00 + 0.80 + 0.40 = 9.20 USD
  let expectedCost = 9.20

  var ledger = UsageLedger()
  ledger.record(
    UsageEvent(provider: .claudeCode, model: "claude-opus-5-5", day: day, hour: 12, tokens: tokens)
  )

  let directCost = try #require(ledger.cost(for: "claude-opus-5-5", tokens: tokens))
  #expect(abs(directCost - expectedCost) < 0.00001)

  let summary = ledger.summary(period: .today, now: date, calendar: calendar)
  #expect(abs(summary.costUSD - expectedCost) < 0.00001)
  #expect(abs(try #require(summary.costByProvider[.claudeCode]) - expectedCost) < 0.00001)
  #expect(!summary.hasUnknownModels)
}

@Test func usageLedger_dayBoundariesInSpecifiedTimeZone() throws {
  let nyTimeZone = try #require(TimeZone(identifier: "America/New_York"))
  var nyCalendar = Calendar(identifier: .gregorian)
  nyCalendar.timeZone = nyTimeZone

  let tokyoTimeZone = try #require(TimeZone(identifier: "Asia/Tokyo"))
  var tokyoCalendar = Calendar(identifier: .gregorian)
  tokyoCalendar.timeZone = tokyoTimeZone

  // Timestamp 2026-11-08 02:30:00 UTC
  // In NY (UTC-5): 2026-11-07 21:30:00 (day = 2026-11-07, hour = 21)
  // In Tokyo (UTC+9): 2026-11-08 11:30:00 (day = 2026-11-08, hour = 11)
  let line = """
    {"type":"assistant","timestamp":"2026-11-08T02:30:00Z",\
    "message":{"id":"msg-tz-1","model":"claude-sonnet-5-5",\
    "usage":{"input_tokens":100,"output_tokens":20}}}
    """

  var seenNY = Set<String>()
  let nyEvents = parseClaudeUsage(lines: [line], seenMessageIds: &seenNY, calendar: nyCalendar)
  let nyEvent = try #require(nyEvents.first)
  #expect(nyEvent.hour == 21)

  let nyDayComps = nyCalendar.dateComponents([.year, .month, .day], from: nyEvent.day)
  #expect(nyDayComps.year == 2026)
  #expect(nyDayComps.month == 11)
  #expect(nyDayComps.day == 7)

  var seenTokyo = Set<String>()
  let tokyoEvents = parseClaudeUsage(
    lines: [line], seenMessageIds: &seenTokyo, calendar: tokyoCalendar)
  let tokyoEvent = try #require(tokyoEvents.first)
  #expect(tokyoEvent.hour == 11)

  let tokyoDayComps = tokyoCalendar.dateComponents([.year, .month, .day], from: tokyoEvent.day)
  #expect(tokyoDayComps.year == 2026)
  #expect(tokyoDayComps.month == 11)
  #expect(tokyoDayComps.day == 8)
}

@Test func usageLedger_seriesWithZeros() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
  let date = Date(timeIntervalSince1970: 1_700_000_000)
  let todayStart = calendar.startOfDay(for: date)

  var ledger = UsageLedger()
  ledger.record(
    UsageEvent(
      provider: .claudeCode,
      model: "claude-sonnet-5-5",
      day: todayStart,
      hour: 4,
      tokens: TokenUsage(input: 1_000_000, output: 0)
    )
  )

  let points = ledger.series(period: .today, now: date, calendar: calendar)
  #expect(points.count == 24)

  for hour in 0..<24 {
    let point = points[hour]
    if hour == 4 {
      #expect(point.tokens.input == 1_000_000)
      #expect(point.costUSD > 0.0)
    } else {
      #expect(point.tokens == .zero)
      #expect(point.costUSD == 0.0)
    }
  }

  let weekPoints = ledger.series(period: .week, now: date, calendar: calendar)
  #expect(weekPoints.count == 7)
  let todayPoint = try #require(weekPoints.last)
  #expect(todayPoint.tokens.input == 1_000_000)

  for point in weekPoints.dropLast() {
    #expect(point.tokens == .zero)
    #expect(point.costUSD == 0.0)
  }
}
