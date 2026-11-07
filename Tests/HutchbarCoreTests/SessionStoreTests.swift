// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let baseTestDate = Date(timeIntervalSince1970: 1_794_081_600)

@MainActor
@Test func sessionStore_waitingSort_approvalBeforeInput() throws {
  let store = SessionStore()
  let inputSession = SessionSnapshot(
    id: "input-1",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "project-a",
    lastActivity: baseTestDate.addingTimeInterval(-600),
    waitingSince: baseTestDate.addingTimeInterval(-600)
  )
  let approvalSession = SessionSnapshot(
    id: "approval-1",
    agent: .claudeCode,
    state: .waitingForApproval,
    projectName: "project-b",
    lastActivity: baseTestDate.addingTimeInterval(-60),
    waitingSince: baseTestDate.addingTimeInterval(-60)
  )

  store.apply(.session(inputSession), now: baseTestDate)
  store.apply(.session(approvalSession), now: baseTestDate)

  let waiting = store.waiting
  #expect(waiting.count == 2)
  let first = try #require(waiting.first)
  let last = try #require(waiting.last)
  #expect(first.id == "approval-1")
  #expect(last.id == "input-1")
}

@MainActor
@Test func sessionStore_waitingSort_longestWaitingFirst() throws {
  let store = SessionStore()
  let olderApproval = SessionSnapshot(
    id: "app-old",
    agent: .claudeCode,
    state: .waitingForApproval,
    projectName: "project",
    lastActivity: baseTestDate.addingTimeInterval(-300),
    waitingSince: baseTestDate.addingTimeInterval(-300)
  )
  let newerApproval = SessionSnapshot(
    id: "app-new",
    agent: .claudeCode,
    state: .waitingForApproval,
    projectName: "project",
    lastActivity: baseTestDate.addingTimeInterval(-60),
    waitingSince: baseTestDate.addingTimeInterval(-60)
  )

  store.apply(.session(newerApproval), now: baseTestDate)
  store.apply(.session(olderApproval), now: baseTestDate)

  let waiting = store.waiting
  #expect(waiting.count == 2)
  let first = try #require(waiting.first)
  let last = try #require(waiting.last)
  #expect(first.id == "app-old")
  #expect(last.id == "app-new")
}

@MainActor
@Test func sessionStore_workingSort_mostRecentActivityFirst() throws {
  let store = SessionStore()
  let activeOlder = SessionSnapshot(
    id: "work-old",
    agent: .codex,
    state: .running,
    projectName: "p1",
    lastActivity: baseTestDate.addingTimeInterval(-120)
  )
  let activeNewer = SessionSnapshot(
    id: "work-new",
    agent: .claudeCode,
    state: .running,
    projectName: "p2",
    lastActivity: baseTestDate.addingTimeInterval(-10)
  )

  store.apply(.session(activeOlder), now: baseTestDate)
  store.apply(.session(activeNewer), now: baseTestDate)

  let working = store.working
  #expect(working.count == 2)
  let first = try #require(working.first)
  let last = try #require(working.last)
  #expect(first.id == "work-new")
  #expect(last.id == "work-old")
}

@MainActor
@Test func sessionStore_finishedVisibility_toggle() {
  let store = SessionStore()
  let finishedSession = SessionSnapshot(
    id: "fin-1",
    agent: .claudeCode,
    state: .finished,
    projectName: "done",
    lastActivity: baseTestDate.addingTimeInterval(-30)
  )
  store.apply(.session(finishedSession), now: baseTestDate)

  #expect(store.showFinished == false)
  #expect(store.finished.isEmpty)

  store.showFinished = true
  #expect(store.finished.count == 1)
  #expect(store.finished.first?.id == "fin-1")
}

@MainActor
@Test func sessionStore_waitingCount() {
  let store = SessionStore()
  let appSession = SessionSnapshot(
    id: "w1", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTestDate, waitingSince: baseTestDate
  )
  let inSession = SessionSnapshot(
    id: "w2", agent: .codex, state: .waitingForInput, projectName: "p",
    lastActivity: baseTestDate, waitingSince: baseTestDate
  )
  let runSession = SessionSnapshot(
    id: "r1", agent: .claudeCode, state: .running, projectName: "p",
    lastActivity: baseTestDate
  )
  let finSession = SessionSnapshot(
    id: "f1", agent: .claudeCode, state: .finished, projectName: "p",
    lastActivity: baseTestDate
  )

  store.apply(.session(appSession), now: baseTestDate)
  store.apply(.session(inSession), now: baseTestDate)
  store.apply(.session(runSession), now: baseTestDate)
  store.apply(.session(finSession), now: baseTestDate)

  #expect(store.waitingCount == 2)
}

@MainActor
@Test func sessionStore_hookMerge_afterSessionExists() throws {
  let store = SessionStore()
  let session = SessionSnapshot(
    id: "claude-live",
    agent: .claudeCode,
    state: .running,
    projectName: "repo",
    lastActivity: baseTestDate
  )
  store.apply(.session(session), now: baseTestDate)

  let hookApproval = HookEvent(
    ts: baseTestDate.addingTimeInterval(5),
    session: "claude-live",
    kind: .approval
  )
  store.apply(.hookEvent(hookApproval), now: baseTestDate.addingTimeInterval(5))

  let updated = try #require(store.session(agent: .claudeCode, id: "claude-live"))
  #expect(updated.state == .waitingForApproval)
  #expect(updated.waitingSince == baseTestDate.addingTimeInterval(5))
  #expect(updated.lastActivity == baseTestDate.addingTimeInterval(5))

  let hookPrompt = HookEvent(
    ts: baseTestDate.addingTimeInterval(10),
    session: "claude-live",
    kind: .prompt
  )
  store.apply(.hookEvent(hookPrompt), now: baseTestDate.addingTimeInterval(10))

  let runningAgain = try #require(store.session(agent: .claudeCode, id: "claude-live"))
  #expect(runningAgain.state == .running)
  #expect(runningAgain.waitingSince == nil)
}

@MainActor
@Test func sessionStore_hookMerge_beforeSessionAppears() throws {
  let store = SessionStore()
  let earlyHook = HookEvent(
    ts: baseTestDate.addingTimeInterval(20),
    session: "future-sess",
    kind: .approval
  )
  store.apply(.hookEvent(earlyHook), now: baseTestDate)
  #expect(store.pendingHookCount == 1)

  let transcriptSession = SessionSnapshot(
    id: "future-sess",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "my-tool",
    lastActivity: baseTestDate.addingTimeInterval(10),
    waitingSince: baseTestDate.addingTimeInterval(10)
  )
  store.apply(.session(transcriptSession), now: baseTestDate.addingTimeInterval(25))

  #expect(store.pendingHookCount == 0)
  let materialized = try #require(store.session(agent: .claudeCode, id: "future-sess"))
  #expect(materialized.state == .waitingForApproval)
  #expect(materialized.waitingSince == baseTestDate.addingTimeInterval(20))
  #expect(materialized.projectName == "my-tool")
}

@MainActor
@Test func sessionStore_hookPendingLimit_dropsOldest() {
  let store = SessionStore()
  for index in 0..<55 {
    let hook = HookEvent(
      ts: baseTestDate.addingTimeInterval(Double(index)),
      session: "ghost-\(index)",
      kind: .idle
    )
    store.apply(.hookEvent(hook), now: baseTestDate)
  }

  #expect(store.pendingHookCount == SessionStore.maxPendingHookEvents)

  // Sessions 0..4 should have been dropped, ghost-5 should still be present.
  let session0 = SessionSnapshot(
    id: "ghost-0", agent: .claudeCode, state: .running, projectName: "p",
    lastActivity: baseTestDate
  )
  store.apply(.session(session0), now: baseTestDate)
  #expect(store.session(agent: .claudeCode, id: "ghost-0")?.state == .running)

  let session5 = SessionSnapshot(
    id: "ghost-5", agent: .claudeCode, state: .running, projectName: "p",
    lastActivity: baseTestDate
  )
  store.apply(.session(session5), now: baseTestDate)
  #expect(store.session(agent: .claudeCode, id: "ghost-5")?.state == .waitingForInput)
}

@MainActor
@Test func sessionStore_sessionMerge_newerHookNotOverwrittenByOlderTranscript() throws {
  let store = SessionStore()
  let initial = SessionSnapshot(
    id: "sess-stable",
    agent: .claudeCode,
    state: .running,
    projectName: "alpha",
    lastActivity: baseTestDate
  )
  store.apply(.session(initial), now: baseTestDate)

  let hook = HookEvent(
    ts: baseTestDate.addingTimeInterval(60),
    session: "sess-stable",
    kind: .approval
  )
  store.apply(.hookEvent(hook), now: baseTestDate.addingTimeInterval(60))

  let delayedTranscript = SessionSnapshot(
    id: "sess-stable",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "alpha",
    lastActivity: baseTestDate.addingTimeInterval(30),
    waitingSince: baseTestDate.addingTimeInterval(30)
  )
  store.apply(.session(delayedTranscript), now: baseTestDate.addingTimeInterval(70))

  let current = try #require(store.session(agent: .claudeCode, id: "sess-stable"))
  #expect(current.state == .waitingForApproval)
  #expect(current.lastActivity == baseTestDate.addingTimeInterval(60))
}

@MainActor
@Test func sessionStore_prune_removesFinishedOlderThan24Hours() {
  let store = SessionStore()
  let recentFinished = SessionSnapshot(
    id: "f-recent", agent: .claudeCode, state: .finished, projectName: "p",
    lastActivity: baseTestDate.addingTimeInterval(-3600)
  )
  let expiredFinished = SessionSnapshot(
    id: "f-expired", agent: .claudeCode, state: .finished, projectName: "p",
    lastActivity: baseTestDate.addingTimeInterval(-(25 * 3600))
  )
  let oldRunning = SessionSnapshot(
    id: "r-old", agent: .claudeCode, state: .running, projectName: "p",
    lastActivity: baseTestDate.addingTimeInterval(-(30 * 3600))
  )

  store.apply(.session(recentFinished), now: baseTestDate)
  store.apply(.session(expiredFinished), now: baseTestDate)
  store.apply(.session(oldRunning), now: baseTestDate)
  #expect(store.sessionCount == 3)

  store.prune(now: baseTestDate)
  #expect(store.sessionCount == 2)
  #expect(store.session(agent: .claudeCode, id: "f-expired") == nil)
  #expect(store.session(agent: .claudeCode, id: "f-recent") != nil)
  #expect(store.session(agent: .claudeCode, id: "r-old") != nil)
}

@MainActor
@Test func sessionStore_prune_500LimitDropsOldestFinished() {
  let store = SessionStore()
  // Add 490 running sessions.
  for index in 0..<490 {
    let running = SessionSnapshot(
      id: "run-\(index)", agent: .claudeCode, state: .running, projectName: "p",
      lastActivity: baseTestDate
    )
    store.apply(.session(running), now: baseTestDate)
  }

  // Add 20 recent finished sessions (within 24 hours).
  for index in 0..<20 {
    let finished = SessionSnapshot(
      id: "fin-\(index)", agent: .claudeCode, state: .finished, projectName: "p",
      lastActivity: baseTestDate.addingTimeInterval(Double(index * 60))
    )
    store.apply(.session(finished), now: baseTestDate)
  }

  #expect(store.sessionCount == 510)
  store.prune(now: baseTestDate.addingTimeInterval(3000))
  #expect(store.sessionCount == 500)

  // Oldest 10 finished sessions (fin-0 .. fin-9) should have been pruned.
  for index in 0..<10 {
    #expect(store.session(agent: .claudeCode, id: "fin-\(index)") == nil)
  }
  for index in 10..<20 {
    #expect(store.session(agent: .claudeCode, id: "fin-\(index)") != nil)
  }
}

@MainActor
@Test func sessionStore_quotas_replacementAndMaxFiveHour() {
  let store = SessionStore()
  #expect(store.maxFiveHourQuota == nil)

  let quotaA1 = AccountQuota(
    agent: .claudeCode,
    accountName: "personal",
    windows: [
      QuotaWindow(windowMinutes: 300, usedPercent: 42.0, resetsAt: nil),
      QuotaWindow(windowMinutes: 10080, usedPercent: 15.0, resetsAt: nil),
    ],
    observedAt: baseTestDate
  )
  store.apply(.quota(quotaA1), now: baseTestDate)
  #expect(store.maxFiveHourQuota == 42.0)

  let quotaB = AccountQuota(
    agent: .claudeCode,
    accountName: "work",
    windows: [
      QuotaWindow(windowMinutes: 300, usedPercent: 88.0, resetsAt: nil)
    ],
    observedAt: baseTestDate
  )
  store.apply(.quota(quotaB), now: baseTestDate)
  #expect(store.maxFiveHourQuota == 88.0)

  // Newer quota for "personal" replaces old quotaA1.
  let quotaA2 = AccountQuota(
    agent: .claudeCode,
    accountName: "personal",
    windows: [
      QuotaWindow(windowMinutes: 300, usedPercent: 95.0, resetsAt: nil)
    ],
    observedAt: baseTestDate.addingTimeInterval(60)
  )
  store.apply(.quota(quotaA2), now: baseTestDate.addingTimeInterval(60))
  #expect(store.maxFiveHourQuota == 95.0)
  #expect(store.quotas.count == 2)
}

@MainActor
@Test func sessionStore_sourceStatus() {
  let store = SessionStore()
  #expect(store.sourceStatus.isEmpty)

  store.apply(.sourceStatus(.claudeTranscripts, available: true), now: baseTestDate)
  store.apply(.sourceStatus(.claudeHooks, available: false), now: baseTestDate)

  #expect(store.sourceStatus[.claudeTranscripts] == true)
  #expect(store.sourceStatus[.claudeHooks] == false)
  #expect(store.sourceStatus[.codexSessions] == nil)
}
