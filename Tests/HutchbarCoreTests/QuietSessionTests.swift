// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let quietTestBaseDate = Date(timeIntervalSince1970: 1_794_081_600)

@MainActor
@Test func quietSessions_fiftyNineMinutes_inWaitingAndNotInQuiet() throws {
  let store = SessionStore()
  let waitingSince = quietTestBaseDate.addingTimeInterval(-59 * 60)
  let session = SessionSnapshot(
    id: "sess-waiting-59m",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "project-a",
    lastActivity: waitingSince,
    waitingSince: waitingSince
  )

  store.apply(.session(session), now: quietTestBaseDate)

  let waitingList = store.waiting(now: quietTestBaseDate)
  let quietList = store.quiet(now: quietTestBaseDate)

  #expect(waitingList.count == 1)
  #expect(waitingList.first?.id == "sess-waiting-59m")
  #expect(store.waitingCount(now: quietTestBaseDate) == 1)
  #expect(quietList.isEmpty)
}

@MainActor
@Test func quietSessions_sixtyOneMinutes_inQuietAndNotInWaiting() throws {
  let store = SessionStore()
  let waitingSince = quietTestBaseDate.addingTimeInterval(-61 * 60)
  let session = SessionSnapshot(
    id: "sess-quiet-61m",
    agent: .claudeCode,
    state: .waitingForApproval,
    projectName: "project-b",
    lastActivity: waitingSince,
    waitingSince: waitingSince
  )

  store.apply(.session(session), now: quietTestBaseDate)

  let waitingList = store.waiting(now: quietTestBaseDate)
  let quietList = store.quiet(now: quietTestBaseDate)

  #expect(waitingList.isEmpty)
  #expect(store.waitingCount(now: quietTestBaseDate) == 0)
  #expect(quietList.count == 1)
  #expect(quietList.first?.id == "sess-quiet-61m")
}

@MainActor
@Test func quietSessions_quietAfterNil_neverQuiet() throws {
  let store = SessionStore(quietAfter: nil)
  let waitingSince = quietTestBaseDate.addingTimeInterval(-24 * 3600)
  let session = SessionSnapshot(
    id: "sess-never-quiet",
    agent: .codex,
    state: .waitingForInput,
    projectName: "project-c",
    lastActivity: waitingSince,
    waitingSince: waitingSince
  )

  store.apply(.session(session), now: quietTestBaseDate)

  let waitingList = store.waiting(now: quietTestBaseDate)
  let quietList = store.quiet(now: quietTestBaseDate)

  #expect(waitingList.count == 1)
  #expect(waitingList.first?.id == "sess-never-quiet")
  #expect(store.waitingCount(now: quietTestBaseDate) == 1)
  #expect(quietList.isEmpty)
}

@MainActor
@Test func quietSessions_newActivity_returnsToWaiting() throws {
  let store = SessionStore()
  let initialTime = quietTestBaseDate.addingTimeInterval(-70 * 60)
  let session = SessionSnapshot(
    id: "sess-reactivate",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "project-d",
    lastActivity: initialTime,
    waitingSince: initialTime
  )
  store.apply(.session(session), now: quietTestBaseDate)

  #expect(store.waitingCount(now: quietTestBaseDate) == 0)
  #expect(store.quiet(now: quietTestBaseDate).count == 1)

  // Agent becomes busy via live status update.
  let busyTime = quietTestBaseDate.addingTimeInterval(30)
  store.apply(
    .liveStatus(sessionId: "sess-reactivate", pid: 101, status: .busy, at: busyTime),
    now: busyTime
  )
  #expect(store.session(agent: .claudeCode, id: "sess-reactivate")?.state == .running)
  #expect(store.quiet(now: busyTime).isEmpty)
  #expect(store.waitingCount(now: busyTime) == 0)

  // Agent becomes idle (waiting for input) again.
  let idleTime = quietTestBaseDate.addingTimeInterval(60)
  store.apply(
    .liveStatus(sessionId: "sess-reactivate", pid: 101, status: .idle, at: idleTime),
    now: idleTime
  )

  let checkTime = idleTime.addingTimeInterval(120)
  let waitingList = store.waiting(now: checkTime)
  #expect(waitingList.count == 1)
  #expect(waitingList.first?.id == "sess-reactivate")
  #expect(store.waitingCount(now: checkTime) == 1)
  #expect(store.quiet(now: checkTime).isEmpty)
}

@MainActor
@Test func quietSessions_pillAndMenuBarCounter_ignoreQuiet() throws {
  let store = SessionStore()
  let quietTime = quietTestBaseDate.addingTimeInterval(-65 * 60)
  let quietSession = SessionSnapshot(
    id: "sess-quiet-ignored",
    agent: .claudeCode,
    state: .waitingForApproval,
    projectName: "project-quiet",
    lastActivity: quietTime,
    waitingSince: quietTime
  )
  store.apply(.session(quietSession), now: quietTestBaseDate)

  // Status icon model ignores quiet session.
  let iconModelQuietOnly = StatusIconModel(store: store, now: quietTestBaseDate)
  #expect(iconModelQuietOnly.waitingCount == 0)
  #expect(iconModelQuietOnly.pillStyle == .none)

  // Attention decision returns nil for quiet session.
  let decisionQuietOnly = store.attentionDecision(
    now: quietTestBaseDate,
    threshold: 60,
    state: AttentionPolicy.State()
  )
  #expect(decisionQuietOnly.sessionToShow == nil)

  // Add an active waiting session (waiting for 5 minutes).
  let freshTime = quietTestBaseDate.addingTimeInterval(-300)
  let activeSession = SessionSnapshot(
    id: "sess-active-fresh",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "project-fresh",
    lastActivity: freshTime,
    waitingSince: freshTime
  )
  store.apply(.session(activeSession), now: quietTestBaseDate)

  let iconModelWithActive = StatusIconModel(store: store, now: quietTestBaseDate)
  #expect(iconModelWithActive.waitingCount == 1)
  #expect(iconModelWithActive.pillStyle == .yourTurn)

  let decisionWithActive = store.attentionDecision(
    now: quietTestBaseDate,
    threshold: 60,
    state: AttentionPolicy.State()
  )
  let chosenSession = try #require(decisionWithActive.sessionToShow)
  #expect(chosenSession.id == "sess-active-fresh")
}

@MainActor
@Test func quietSessions_quietListSortedByLastActivityDescending() throws {
  let store = SessionStore()
  let sessionOlderActivity = SessionSnapshot(
    id: "sess-older-act",
    agent: .codex,
    state: .waitingForInput,
    projectName: "project-older",
    lastActivity: quietTestBaseDate.addingTimeInterval(-5000),
    waitingSince: quietTestBaseDate.addingTimeInterval(-5000)
  )
  let sessionNewerActivity = SessionSnapshot(
    id: "sess-newer-act",
    agent: .claudeCode,
    state: .waitingForInput,
    projectName: "project-newer",
    lastActivity: quietTestBaseDate.addingTimeInterval(-4000),
    waitingSince: quietTestBaseDate.addingTimeInterval(-6000)
  )

  store.apply(.session(sessionOlderActivity), now: quietTestBaseDate)
  store.apply(.session(sessionNewerActivity), now: quietTestBaseDate)

  let quietList = store.quiet(now: quietTestBaseDate)
  #expect(quietList.count == 2)
  let first = try #require(quietList.first)
  let last = try #require(quietList.last)
  #expect(first.id == "sess-newer-act")
  #expect(last.id == "sess-older-act")
}
