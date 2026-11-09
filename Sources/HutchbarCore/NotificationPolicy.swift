// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One notification request to be presented to the user.
public struct NotificationRequest: Equatable, Sendable, Identifiable {
  public let id: String
  public let sessionKey: SessionKey
  public let title: String
  public let body: String

  public init(id: String, sessionKey: SessionKey, title: String, body: String) {
    self.id = id
    self.sessionKey = sessionKey
    self.title = title
    self.body = body
  }
}

/// Pure policy for agent waiting notifications.
public struct NotificationPolicy: Sendable {
  public static let maxBurst = 3
  public static let initialOldAgeLimit: TimeInterval = 3600

  /// Unique waiting episode identified by session key and when waiting began.
  public struct Episode: Hashable, Sendable {
    public let sessionKey: SessionKey
    public let waitingSince: Date

    public init(sessionKey: SessionKey, waitingSince: Date) {
      self.sessionKey = sessionKey
      self.waitingSince = waitingSince
    }
  }

  /// History of notified episodes and startup state.
  public struct State: Equatable, Sendable {
    public var notifiedEpisodes: Set<Episode>
    public var hasEvaluated: Bool

    public init(notifiedEpisodes: Set<Episode> = [], hasEvaluated: Bool = false) {
      self.notifiedEpisodes = notifiedEpisodes
      self.hasEvaluated = hasEvaluated
    }
  }

  /// Result of evaluating the notification policy.
  public struct Decision: Equatable, Sendable {
    public let requests: [NotificationRequest]
    public let newState: State

    public init(requests: [NotificationRequest], newState: State) {
      self.requests = requests
      self.newState = newState
    }
  }

  public static func makeId(sessionKey: SessionKey, waitingSince: Date) -> String {
    "\(sessionKey.agent.rawValue):\(sessionKey.id):\(waitingSince.timeIntervalSince1970)"
  }

  public static func notificationBody(
    session: SessionSnapshot,
    now: Date = Date(),
    language: L10n.Language? = nil
  ) -> String {
    var parts: [String] = []
    let project = session.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !project.isEmpty {
      parts.append(project)
    }
    if let title = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
      parts.append(title)
    }
    let timeText = formatWaitingTime(since: session.waitingSince, now: now, language: language)
    if !timeText.isEmpty {
      parts.append(timeText)
    }
    return parts.joined(separator: " · ")
  }

  public static func decide(
    waiting: [SessionSnapshot],
    now: Date,
    threshold: TimeInterval?,
    state: State,
    language: L10n.Language? = nil
  ) -> Decision {
    guard let threshold, threshold >= 0 else {
      return Decision(requests: [], newState: state)
    }

    let activeEpisodes = Set(
      waiting.compactMap { session -> Episode? in
        guard let waitingSince = session.waitingSince else { return nil }
        return Episode(sessionKey: session.sessionKey, waitingSince: waitingSince)
      }
    )

    var retainedEpisodes = state.notifiedEpisodes.intersection(activeEpisodes)
    let isInitialRun = !state.hasEvaluated

    var eligibleSessions: [SessionSnapshot] = []

    for session in waiting {
      guard let waitingSince = session.waitingSince else { continue }
      let episode = Episode(sessionKey: session.sessionKey, waitingSince: waitingSince)

      if retainedEpisodes.contains(episode) {
        continue
      }

      let waited = now.timeIntervalSince(waitingSince)
      guard waited >= threshold else { continue }

      if isInitialRun && waited > initialOldAgeLimit {
        retainedEpisodes.insert(episode)
        continue
      }

      eligibleSessions.append(session)
    }

    eligibleSessions.sort { lhs, rhs in
      if lhs.state != rhs.state {
        return lhs.state == .waitingForApproval
      }
      let lhsSince = lhs.waitingSince ?? .distantFuture
      let rhsSince = rhs.waitingSince ?? .distantFuture
      if lhsSince != rhsSince {
        return lhsSince < rhsSince
      }
      return lhs.id < rhs.id
    }

    let allowedSessions = eligibleSessions.prefix(maxBurst)
    var requests: [NotificationRequest] = []

    for session in allowedSessions {
      guard let waitingSince = session.waitingSince else { continue }
      let episode = Episode(sessionKey: session.sessionKey, waitingSince: waitingSince)
      retainedEpisodes.insert(episode)

      let requestId = makeId(sessionKey: session.sessionKey, waitingSince: waitingSince)
      let title = L10n.notificationTitle(
        agentName: session.agent.info.displayName,
        state: session.state,
        language: language
      )
      let body = notificationBody(session: session, now: now, language: language)
      requests.append(
        NotificationRequest(
          id: requestId,
          sessionKey: session.sessionKey,
          title: title,
          body: body
        )
      )
    }

    for session in eligibleSessions.dropFirst(maxBurst) {
      guard let waitingSince = session.waitingSince else { continue }
      let episode = Episode(sessionKey: session.sessionKey, waitingSince: waitingSince)
      retainedEpisodes.insert(episode)
    }

    let nextState = State(notifiedEpisodes: retainedEpisodes, hasEvaluated: true)
    return Decision(requests: requests, newState: nextState)
  }

  public static func evaluate(
    waiting: [SessionSnapshot],
    now: Date,
    threshold: TimeInterval?,
    state: State,
    language: L10n.Language? = nil
  ) -> Decision {
    decide(waiting: waiting, now: now, threshold: threshold, state: state, language: language)
  }
}
