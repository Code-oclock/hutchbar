// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import Testing

private final class TestClockBox: @unchecked Sendable {
  private let lock = NSLock()
  private var current: Date

  init(date: Date) {
    self.current = date
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    current = current.addingTimeInterval(seconds)
  }
}

private actor TargetCallTracker {
  private var counts: [String: Int] = [:]

  init() {}

  func record(id: String) {
    counts[id, default: 0] += 1
  }

  func count(for id: String) -> Int {
    counts[id] ?? 0
  }

  func totalCount() -> Int {
    counts.values.reduce(0, +)
  }
}

private actor FailureToggleBox {
  private var isFailing = false

  init() {}

  func setFail(_ value: Bool) {
    isFailing = value
  }

  func shouldFail() -> Bool {
    isFailing
  }
}

private actor StreamCollector {
  private var items: [SourceUpdate] = []
  private var loopTask: Task<Void, Never>?

  init() {}

  func start(stream: AsyncStream<SourceUpdate>) {
    loopTask = Task {
      for await update in stream {
        self.append(update)
      }
    }
  }

  func stop() {
    loopTask?.cancel()
    loopTask = nil
  }

  func append(_ item: SourceUpdate) {
    items.append(item)
  }

  func takeUpdates() -> [SourceUpdate] {
    let current = items
    items = []
    return current
  }
}

private func makeQuota(
  account: String = "alice",
  agent: AgentKind = .claudeCode,
  windows: [QuotaWindow] = [QuotaWindow(windowMinutes: 300, usedPercent: 10.0, resetsAt: nil)],
  observedAt: Date
) -> AccountQuota {
  AccountQuota(
    agent: agent,
    accountName: account,
    windows: windows,
    observedAt: observedAt,
    source: .agentCLI
  )
}

@Test func quotaPoller_firstTickPollsMostOverdueTargetAndEmitsQuota() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)
  let tracker = TargetCallTracker()

  let targetOne = QuotaProbeTarget(
    id: "target-1",
    agent: .claudeCode,
    source: .claudeUsage,
    initialScheduledAt: baseDate.addingTimeInterval(-100),
    read: { date in
      await tracker.record(id: "target-1")
      return .success(makeQuota(account: "user-1", observedAt: date))
    }
  )

  let targetTwo = QuotaProbeTarget(
    id: "target-2",
    agent: .claudeCode,
    source: .claudeUsage,
    initialScheduledAt: baseDate.addingTimeInterval(-10),
    read: { date in
      await tracker.record(id: "target-2")
      return .success(makeQuota(account: "user-2", observedAt: date))
    }
  )

  let poller = QuotaPoller(targets: [targetTwo, targetOne], now: { clock.now() })
  let collector = StreamCollector()
  await collector.start(stream: poller.updates)

  await poller.tick()
  try? await Task.sleep(nanoseconds: 10_000_000)

  let targetOneCount = await tracker.count(for: "target-1")
  let targetTwoCount = await tracker.count(for: "target-2")
  #expect(targetOneCount == 1)
  #expect(targetTwoCount == 0)

  let updates = await collector.takeUpdates()
  let quotaUpdate = updates.first {
    if case .quota(let received) = $0, received.accountName == "user-1" {
      return true
    }
    return false
  }
  #expect(quotaUpdate != nil)
  await collector.stop()
}

@Test func quotaPoller_singleTickPerformsExactlyOneProbe() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)
  let tracker = TargetCallTracker()

  let targetAlpha = QuotaProbeTarget(
    id: "target-alpha",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in
      await tracker.record(id: "target-alpha")
      return .success(makeQuota(account: "alpha", observedAt: date))
    }
  )

  let targetBeta = QuotaProbeTarget(
    id: "target-beta",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in
      await tracker.record(id: "target-beta")
      return .success(makeQuota(account: "beta", observedAt: date))
    }
  )

  let poller = QuotaPoller(targets: [targetAlpha, targetBeta], now: { clock.now() })

  await poller.tick()
  let totalAfterFirst = await tracker.totalCount()
  #expect(totalAfterFirst == 1)

  await poller.tick()
  let totalAfterSecond = await tracker.totalCount()
  #expect(totalAfterSecond == 2)
}

@Test func quotaPoller_pollIntervalRespectsPanelVisibility() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)

  let targetOne = QuotaProbeTarget(
    id: "target-bg",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in .success(makeQuota(account: "bg", observedAt: date)) }
  )

  let poller = QuotaPoller(targets: [targetOne], now: { clock.now() })

  await poller.tick()
  let dueBackground = await poller.nextDue(for: "target-bg")
  #expect(dueBackground == baseDate.addingTimeInterval(300))

  await poller.setPanelVisible(true)
  clock.advance(by: 300)
  await poller.tick()
  let duePanelOpen = await poller.nextDue(for: "target-bg")
  #expect(duePanelOpen == baseDate.addingTimeInterval(360))
}

@Test func quotaPoller_schedulesResetWindowPlusSixtySeconds() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)
  let resetDate = baseDate.addingTimeInterval(120)

  let target = QuotaProbeTarget(
    id: "target-reset",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in
      let window = QuotaWindow(
        windowMinutes: 300,
        usedPercent: 50.0,
        resetsAt: resetDate
      )
      return .success(makeQuota(account: "reset-user", windows: [window], observedAt: date))
    }
  )

  let poller = QuotaPoller(targets: [target], now: { clock.now() })
  await poller.tick()

  let scheduledDue = await poller.nextDue(for: "target-reset")
  #expect(scheduledDue == resetDate.addingTimeInterval(60))
}

@Test func quotaPoller_unreachableBackoffLadderAndResetOnSuccess() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)
  let box = FailureToggleBox()

  let target = QuotaProbeTarget(
    id: "target-ladder",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in
      let shouldFail = await box.shouldFail()
      if shouldFail {
        return .failure(.unreachable)
      }
      return .success(makeQuota(account: "recovering", observedAt: date))
    }
  )

  let poller = QuotaPoller(targets: [target], now: { clock.now() })

  await box.setFail(true)
  await poller.tick()
  #expect(await poller.nextDue(for: "target-ladder") == baseDate.addingTimeInterval(300))

  clock.advance(by: 300)
  await poller.tick()
  #expect(await poller.nextDue(for: "target-ladder") == baseDate.addingTimeInterval(900))

  clock.advance(by: 600)
  await poller.tick()
  #expect(await poller.nextDue(for: "target-ladder") == baseDate.addingTimeInterval(2100))

  clock.advance(by: 1200)
  await poller.tick()
  #expect(await poller.nextDue(for: "target-ladder") == baseDate.addingTimeInterval(3900))

  clock.advance(by: 1800)
  await poller.tick()
  #expect(await poller.nextDue(for: "target-ladder") == baseDate.addingTimeInterval(5700))

  await box.setFail(false)
  clock.advance(by: 1800)
  await poller.tick()
  #expect(await poller.nextDue(for: "target-ladder") == baseDate.addingTimeInterval(6000))

  await box.setFail(true)
  clock.advance(by: 300)
  await poller.tick()
  #expect(await poller.nextDue(for: "target-ladder") == baseDate.addingTimeInterval(6300))
}

@Test func quotaPoller_needsSignInPostponesByEighteenHundredSeconds() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)

  let target = QuotaProbeTarget(
    id: "target-signin",
    agent: .codex,
    source: .codexUsage,
    read: { _ in .failure(.needsSignIn) }
  )

  let poller = QuotaPoller(targets: [target], now: { clock.now() })
  await poller.tick()

  let scheduledDue = await poller.nextDue(for: "target-signin")
  #expect(scheduledDue == baseDate.addingTimeInterval(1800))
}

@Test func quotaPoller_sourceStatusEmittedOnlyOnChange() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)
  let box = FailureToggleBox()

  let target = QuotaProbeTarget(
    id: "target-status",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in
      let shouldFail = await box.shouldFail()
      if shouldFail {
        return .failure(.unreachable)
      }
      return .success(makeQuota(account: "status-test", observedAt: date))
    }
  )

  let poller = QuotaPoller(targets: [target], now: { clock.now() })
  let collector = StreamCollector()
  await collector.start(stream: poller.updates)

  // 1. First poll succeeds -> source becomes available
  await poller.tick()
  try? await Task.sleep(nanoseconds: 10_000_000)
  let updatesFirst = await collector.takeUpdates()
  let hasAvailableTrue = updatesFirst.contains(.sourceStatus(.claudeUsage, available: true))
  #expect(hasAvailableTrue)

  // 2. Second poll succeeds -> status unchanged, no sourceStatus update emitted
  clock.advance(by: 300)
  await poller.tick()
  try? await Task.sleep(nanoseconds: 10_000_000)
  let updatesSecond = await collector.takeUpdates()
  let hasAnyStatusSecond = updatesSecond.contains {
    if case .sourceStatus = $0 { return true }
    return false
  }
  #expect(!hasAnyStatusSecond)

  // 3. Third poll fails -> source becomes unavailable
  await box.setFail(true)
  clock.advance(by: 300)
  await poller.tick()
  try? await Task.sleep(nanoseconds: 10_000_000)
  let updatesThird = await collector.takeUpdates()
  let hasAvailableFalse = updatesThird.contains(.sourceStatus(.claudeUsage, available: false))
  #expect(hasAvailableFalse)

  // 4. Fourth poll fails -> status unchanged, no sourceStatus update emitted
  clock.advance(by: 300)
  await poller.tick()
  try? await Task.sleep(nanoseconds: 10_000_000)
  let updatesFourth = await collector.takeUpdates()
  let hasAnyStatusFourth = updatesFourth.contains {
    if case .sourceStatus = $0 { return true }
    return false
  }
  #expect(!hasAnyStatusFourth)

  await collector.stop()
}

@Test func quotaPoller_panelOpenMakesOldTargetsOverdueAndPreservesFresh() async {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let clock = TestClockBox(date: baseDate)

  let targetOld = QuotaProbeTarget(
    id: "target-old",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in .success(makeQuota(account: "old-user", observedAt: date)) }
  )

  let targetFresh = QuotaProbeTarget(
    id: "target-fresh",
    agent: .claudeCode,
    source: .claudeUsage,
    read: { date in .success(makeQuota(account: "fresh-user", observedAt: date)) }
  )

  let poller = QuotaPoller(targets: [targetOld, targetFresh], now: { clock.now() })

  await poller.tick()
  #expect(await poller.nextDue(for: "target-old") == baseDate.addingTimeInterval(300))

  clock.advance(by: 70)

  await poller.tick()
  #expect(await poller.nextDue(for: "target-fresh") == baseDate.addingTimeInterval(370))

  await poller.setPanelVisible(true)

  let oldDueAfterOpen = await poller.nextDue(for: "target-old")
  #expect(oldDueAfterOpen == baseDate.addingTimeInterval(70))

  let freshDueAfterOpen = await poller.nextDue(for: "target-fresh")
  #expect(freshDueAfterOpen == baseDate.addingTimeInterval(370))
}
