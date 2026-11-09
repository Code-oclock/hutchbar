// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let notificationPolicyBaseDate = Date(timeIntervalSince1970: 1_794_081_600)

private func notificationPolicyMakeSession(
  identifier: String,
  agent: AgentKind = .claudeCode,
  state: SessionState = .waitingForApproval,
  projectName: String = "project",
  title: String? = nil,
  waitingSince: Date?
) -> SessionSnapshot {
  SessionSnapshot(
    id: identifier,
    agent: agent,
    state: state,
    projectName: projectName,
    title: title,
    lastActivity: waitingSince ?? notificationPolicyBaseDate,
    waitingSince: waitingSince
  )
}

@Test func notificationPolicy_thresholdNil_returnsEmpty() {
  let session = notificationPolicyMakeSession(
    identifier: "session-1",
    waitingSince: notificationPolicyBaseDate.addingTimeInterval(-100)
  )
  let state = NotificationPolicy.State()
  let decision = NotificationPolicy.decide(
    waiting: [session],
    now: notificationPolicyBaseDate,
    threshold: nil,
    state: state
  )
  #expect(decision.requests.isEmpty)
  #expect(decision.newState == state)
}

@Test func notificationPolicy_thresholdNotReached_returnsEmpty() {
  let session = notificationPolicyMakeSession(
    identifier: "session-1",
    waitingSince: notificationPolicyBaseDate.addingTimeInterval(-30)
  )
  let state = NotificationPolicy.State()
  let decision = NotificationPolicy.decide(
    waiting: [session],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: state
  )
  #expect(decision.requests.isEmpty)
  #expect(decision.newState.notifiedEpisodes.isEmpty)
}

@Test func notificationPolicy_thresholdReached_singleRequest_repeatCallEmpty() throws {
  let session = notificationPolicyMakeSession(
    identifier: "session-1",
    waitingSince: notificationPolicyBaseDate.addingTimeInterval(-120)
  )
  let initialState = NotificationPolicy.State()
  let firstDecision = NotificationPolicy.decide(
    waiting: [session],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: initialState
  )

  #expect(firstDecision.requests.count == 1)
  let request = try #require(firstDecision.requests.first)
  #expect(request.sessionKey == session.sessionKey)

  // Repeat evaluation with the same episode state
  let secondDecision = NotificationPolicy.decide(
    waiting: [session],
    now: notificationPolicyBaseDate.addingTimeInterval(30),
    threshold: 60.0,
    state: firstDecision.newState
  )
  #expect(secondDecision.requests.isEmpty)
}

@Test func notificationPolicy_newWaitingSince_triggersNewRequest() throws {
  let timeFirst = notificationPolicyBaseDate.addingTimeInterval(-200)
  let sessionFirst = notificationPolicyMakeSession(
    identifier: "session-1",
    waitingSince: timeFirst
  )
  let firstDecision = NotificationPolicy.decide(
    waiting: [sessionFirst],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: NotificationPolicy.State()
  )
  #expect(firstDecision.requests.count == 1)

  // Later, the session enters a new waiting episode
  let timeSecond = notificationPolicyBaseDate.addingTimeInterval(300)
  let evaluateTime = notificationPolicyBaseDate.addingTimeInterval(400)
  let sessionSecond = notificationPolicyMakeSession(
    identifier: "session-1",
    waitingSince: timeSecond
  )
  let secondDecision = NotificationPolicy.decide(
    waiting: [sessionSecond],
    now: evaluateTime,
    threshold: 60.0,
    state: firstDecision.newState
  )

  #expect(secondDecision.requests.count == 1)
  let secondRequest = try #require(secondDecision.requests.first)
  #expect(secondRequest.id != firstDecision.requests.first?.id)
}

@Test func notificationPolicy_sessionStopsWaiting_episodeForgotten() throws {
  let waitingTime = notificationPolicyBaseDate.addingTimeInterval(-100)
  let session = notificationPolicyMakeSession(
    identifier: "session-1",
    waitingSince: waitingTime
  )
  let firstDecision = NotificationPolicy.decide(
    waiting: [session],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: NotificationPolicy.State()
  )
  #expect(firstDecision.requests.count == 1)

  // Next cycle: session is no longer waiting (empty list)
  let emptyDecision = NotificationPolicy.decide(
    waiting: [],
    now: notificationPolicyBaseDate.addingTimeInterval(30),
    threshold: 60.0,
    state: firstDecision.newState
  )
  #expect(emptyDecision.requests.isEmpty)
  #expect(emptyDecision.newState.notifiedEpisodes.isEmpty)

  // Third cycle: session waits again with the same timestamp (episode was forgotten)
  let thirdDecision = NotificationPolicy.decide(
    waiting: [session],
    now: notificationPolicyBaseDate.addingTimeInterval(60),
    threshold: 60.0,
    state: emptyDecision.newState
  )
  #expect(thirdDecision.requests.count == 1)
}

@Test func notificationPolicy_burstExceedingThree_cappedAtThree_remainingMarkedNotified() {
  var sessions: [SessionSnapshot] = []
  for index in 1...5 {
    sessions.append(
      notificationPolicyMakeSession(
        identifier: "session-\(index)",
        waitingSince: notificationPolicyBaseDate.addingTimeInterval(-Double(index * 100))
      )
    )
  }

  let firstDecision = NotificationPolicy.decide(
    waiting: sessions,
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: NotificationPolicy.State()
  )

  #expect(firstDecision.requests.count == 3)
  #expect(firstDecision.newState.notifiedEpisodes.count == 5)

  // Next evaluation: remaining two were already marked notified, so 0 requests
  let secondDecision = NotificationPolicy.decide(
    waiting: sessions,
    now: notificationPolicyBaseDate.addingTimeInterval(10),
    threshold: 60.0,
    state: firstDecision.newState
  )
  #expect(secondDecision.requests.isEmpty)
}

@Test func notificationPolicy_initialEvaluation_oldEpisodesSuppressed() {
  // Session waiting for 2 hours (7200 seconds > 1 hour)
  let oldSession = notificationPolicyMakeSession(
    identifier: "old-session",
    waitingSince: notificationPolicyBaseDate.addingTimeInterval(-7200)
  )
  let initialState = NotificationPolicy.State(hasEvaluated: false)
  let decision = NotificationPolicy.decide(
    waiting: [oldSession],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: initialState
  )

  #expect(decision.requests.isEmpty)
  #expect(decision.newState.hasEvaluated)
  #expect(decision.newState.notifiedEpisodes.count == 1)
}

@Test func notificationPolicy_initialEvaluation_freshEpisodesNotSuppressed() {
  // Session waiting for 5 minutes (300 seconds <= 1 hour)
  let freshSession = notificationPolicyMakeSession(
    identifier: "fresh-session",
    waitingSince: notificationPolicyBaseDate.addingTimeInterval(-300)
  )
  let initialState = NotificationPolicy.State(hasEvaluated: false)
  let decision = NotificationPolicy.decide(
    waiting: [freshSession],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: initialState
  )

  #expect(decision.requests.count == 1)
  #expect(decision.newState.hasEvaluated)
}

@Test func notificationPolicy_localizedTexts_russianAndEnglish() throws {
  let waitingDate = notificationPolicyBaseDate.addingTimeInterval(-120)
  let approvalSession = notificationPolicyMakeSession(
    identifier: "claude-session",
    agent: .claudeCode,
    state: .waitingForApproval,
    projectName: "hutchbar",
    title: "Feature",
    waitingSince: waitingDate
  )
  let inputSession = notificationPolicyMakeSession(
    identifier: "codex-session",
    agent: .codex,
    state: .waitingForInput,
    projectName: "backend",
    title: nil,
    waitingSince: waitingDate
  )

  // Russian
  let ruDecision = NotificationPolicy.decide(
    waiting: [approvalSession, inputSession],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: NotificationPolicy.State(),
    language: .ru
  )
  let ruApproval = try #require(
    ruDecision.requests.first { $0.sessionKey == approvalSession.sessionKey }
  )
  let ruInput = try #require(
    ruDecision.requests.first { $0.sessionKey == inputSession.sessionKey }
  )
  #expect(ruApproval.title == "Claude ждёт разрешения")
  #expect(ruApproval.body == "hutchbar · Feature · 2 мин")
  #expect(ruInput.title == "Codex: твой ход")
  #expect(ruInput.body == "backend · 2 мин")

  // English
  let enDecision = NotificationPolicy.decide(
    waiting: [approvalSession, inputSession],
    now: notificationPolicyBaseDate,
    threshold: 60.0,
    state: NotificationPolicy.State(),
    language: .en
  )
  let enApproval = try #require(
    enDecision.requests.first { $0.sessionKey == approvalSession.sessionKey }
  )
  let enInput = try #require(
    enDecision.requests.first { $0.sessionKey == inputSession.sessionKey }
  )
  #expect(enApproval.title == "Claude needs approval")
  #expect(enApproval.body == "hutchbar · Feature · 2m")
  #expect(enInput.title == "Codex: your turn")
  #expect(enInput.body == "backend · 2m")
}
