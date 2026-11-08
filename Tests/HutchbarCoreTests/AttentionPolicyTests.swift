// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let baseTime = Date(timeIntervalSince1970: 1_794_081_600)

@Test func attentionPolicy_thresholdNil_returnsNil() {
  let waiting = [
    SessionSnapshot(
      id: "w1", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
      lastActivity: baseTime.addingTimeInterval(-100),
      waitingSince: baseTime.addingTimeInterval(-100)
    )
  ]
  let state = AttentionPolicy.State()
  let decision = AttentionPolicy.decide(
    waiting: waiting,
    now: baseTime,
    threshold: nil,
    state: state
  )

  #expect(decision.sessionToShow == nil)
  #expect(decision.newState == state)
}

@Test func attentionPolicy_waitedLessThanThreshold_returnsNil() {
  let waiting = [
    SessionSnapshot(
      id: "w1", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
      lastActivity: baseTime.addingTimeInterval(-40),
      waitingSince: baseTime.addingTimeInterval(-40)
    )
  ]
  let state = AttentionPolicy.State()
  let decision = AttentionPolicy.decide(
    waiting: waiting,
    now: baseTime,
    threshold: 60.0,
    state: state
  )

  #expect(decision.sessionToShow == nil)
  #expect(decision.newState == state)
}

@Test func attentionPolicy_waitedLongerThanThreshold_showsLongestWaiting() throws {
  let sessionA = SessionSnapshot(
    id: "sess-a", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-120),
    waitingSince: baseTime.addingTimeInterval(-120)
  )
  let sessionB = SessionSnapshot(
    id: "sess-b", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-80),
    waitingSince: baseTime.addingTimeInterval(-80)
  )

  let state = AttentionPolicy.State()
  let decision = AttentionPolicy.decide(
    waiting: [sessionB, sessionA],
    now: baseTime,
    threshold: 60.0,
    state: state
  )

  let shown = try #require(decision.sessionToShow)
  #expect(shown.id == "sess-a")
  #expect(decision.newState.lastShownKey == sessionA.sessionKey)
  #expect(decision.newState.lastShownAt == baseTime)
}

@Test func attentionPolicy_repeatSameSession_cooldownUnderFiveMinutes_returnsNil() throws {
  let sessionA = SessionSnapshot(
    id: "sess-a", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-120),
    waitingSince: baseTime.addingTimeInterval(-120)
  )

  var state = AttentionPolicy.State()
  let firstDecision = AttentionPolicy.decide(
    waiting: [sessionA],
    now: baseTime,
    threshold: 60.0,
    state: state
  )
  #expect(firstDecision.sessionToShow?.id == "sess-a")
  state = firstDecision.newState

  // Check 60 seconds later (under 5 minutes cooldown).
  let laterTime = baseTime.addingTimeInterval(60)
  let secondDecision = AttentionPolicy.decide(
    waiting: [sessionA],
    now: laterTime,
    threshold: 60.0,
    state: state
  )

  #expect(secondDecision.sessionToShow == nil)
  #expect(secondDecision.newState.lastShownKey == sessionA.sessionKey)
}

@Test func attentionPolicy_repeatSameSession_afterFiveMinutes_showsAgain() throws {
  let sessionA = SessionSnapshot(
    id: "sess-a", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-400),
    waitingSince: baseTime.addingTimeInterval(-400)
  )

  let initialState = AttentionPolicy.State(
    lastShownKey: sessionA.sessionKey,
    lastShownAt: baseTime
  )

  // 300 seconds is 5 minutes; check at 301 seconds.
  let repeatTime = baseTime.addingTimeInterval(301)
  let decision = AttentionPolicy.decide(
    waiting: [sessionA],
    now: repeatTime,
    threshold: 60.0,
    state: initialState
  )

  let shown = try #require(decision.sessionToShow)
  #expect(shown.id == "sess-a")
  #expect(decision.newState.lastShownAt == repeatTime)
}

@Test func attentionPolicy_differentSession_crossingThreshold_showsImmediately() throws {
  let sessionA = SessionSnapshot(
    id: "sess-a", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-200),
    waitingSince: baseTime.addingTimeInterval(-200)
  )
  let sessionB = SessionSnapshot(
    id: "sess-b", agent: .claudeCode, state: .waitingForInput, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-70),
    waitingSince: baseTime.addingTimeInterval(-70)
  )

  // Session A was shown at baseTime.
  let state = AttentionPolicy.State(
    lastShownKey: sessionA.sessionKey,
    lastShownAt: baseTime
  )

  // 30 seconds later, session B crosses threshold and should be shown immediately.
  let stepTime = baseTime.addingTimeInterval(30)
  let decision = AttentionPolicy.decide(
    waiting: [sessionA, sessionB],
    now: stepTime,
    threshold: 60.0,
    state: state
  )

  let shown = try #require(decision.sessionToShow)
  #expect(shown.id == "sess-b")
  #expect(decision.newState.lastShownKey == sessionB.sessionKey)
  #expect(decision.newState.lastShownAt == stepTime)
}

@Test func attentionPolicy_approvalPrioritizedOnSameWaitingTime() throws {
  let sessionApp = SessionSnapshot(
    id: "app-1", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-100),
    waitingSince: baseTime.addingTimeInterval(-100)
  )
  let sessionIn = SessionSnapshot(
    id: "in-1", agent: .claudeCode, state: .waitingForInput, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-100),
    waitingSince: baseTime.addingTimeInterval(-100)
  )

  let state = AttentionPolicy.State()
  let decision = AttentionPolicy.decide(
    waiting: [sessionIn, sessionApp],
    now: baseTime,
    threshold: 60.0,
    state: state
  )

  let shown = try #require(decision.sessionToShow)
  #expect(shown.id == "app-1")
}

@Test func attentionPolicy_emptyWaitingList_returnsNil() {
  let state = AttentionPolicy.State()
  let decision = AttentionPolicy.decide(
    waiting: [],
    now: baseTime,
    threshold: 60.0,
    state: state
  )

  #expect(decision.sessionToShow == nil)
  #expect(decision.newState == state)
}

@Test func attentionPolicy_codexAndClaudeAgents_differentiatedByKey() throws {
  let claudeSession = SessionSnapshot(
    id: "same-id", agent: .claudeCode, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-100),
    waitingSince: baseTime.addingTimeInterval(-100)
  )
  let codexSession = SessionSnapshot(
    id: "same-id", agent: .codex, state: .waitingForApproval, projectName: "p",
    lastActivity: baseTime.addingTimeInterval(-100),
    waitingSince: baseTime.addingTimeInterval(-100)
  )

  // Claude session was shown at baseTime.
  let state = AttentionPolicy.State(
    lastShownKey: claudeSession.sessionKey,
    lastShownAt: baseTime
  )

  // Codex session with same session ID should be eligible immediately.
  let stepTime = baseTime.addingTimeInterval(30)
  let decision = AttentionPolicy.decide(
    waiting: [claudeSession, codexSession],
    now: stepTime,
    threshold: 60.0,
    state: state
  )

  let shown = try #require(decision.sessionToShow)
  #expect(shown.agent == .codex)
  #expect(decision.newState.lastShownKey == codexSession.sessionKey)
}
