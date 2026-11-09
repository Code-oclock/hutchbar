// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private func statusUpdates(_ updates: [SourceUpdate]) -> [SourceUpdate] {
  updates.filter {
    if case .sourceStatus = $0 { return true }
    return false
  }
}

/// Two Claude profiles share one source: one broken profile must not flip it off and on.
@Test func quotaPoller_sourceAvailableWhileAnyTargetAnswers() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)

  let healthy = QuotaProbeTarget(
    id: "claude:healthy",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in .success(makeQuota(account: "healthy", observedAt: date)) }
  )
  let broken = QuotaProbeTarget(
    id: "claude:broken",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { _ in .failure(.unreachable) }
  )

  let poller = QuotaPoller(targets: [healthy, broken], now: { clock.now() })
  let collector = StreamCollector()
  await collector.start(stream: poller.updates)

  // Both targets get polled once, in whatever order the poller picks.
  await poller.tick()
  await poller.tick()
  try? await Task.sleep(nanoseconds: 10_000_000)
  let first = statusUpdates(await collector.takeUpdates())
  #expect(first.last == .sourceStatus(.claudeUsage, available: true))

  // Later rounds: the broken profile keeps failing, the source stays available silently.
  for _ in 0..<4 {
    clock.advance(by: 1900)
    await poller.tick()
  }
  try? await Task.sleep(nanoseconds: 10_000_000)
  #expect(statusUpdates(await collector.takeUpdates()).isEmpty)

  await collector.stop()
}
