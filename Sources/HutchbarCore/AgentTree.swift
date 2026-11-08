// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A node in the hierarchical agent tree representing either a tracked session
/// or an ephemeral child process.
public struct AgentNode: Equatable, Sendable, Identifiable {
  public var id: String {
    if let session {
      return "session:\(session.agent.rawValue):\(session.id)"
    }
    if let ephemeral {
      return "ephemeral:\(ephemeral.id)"
    }
    return "unknown"
  }

  public let session: SessionSnapshot?
  public let ephemeral: EphemeralChild?
  public let children: [AgentNode]

  public init(
    session: SessionSnapshot? = nil,
    ephemeral: EphemeralChild? = nil,
    children: [AgentNode] = []
  ) {
    self.session = session
    self.ephemeral = ephemeral
    self.children = children
  }

  public init(session: SessionSnapshot, children: [AgentNode] = []) {
    self.session = session
    self.ephemeral = nil
    self.children = children
  }

  public init(ephemeral: EphemeralChild, children: [AgentNode] = []) {
    self.session = nil
    self.ephemeral = ephemeral
    self.children = children
  }
}

/// Hierarchical tree of agent sessions partitioned into waiting, working, and quiet groups.
public struct AgentTree: Equatable, Sendable {
  public let waiting: [AgentNode]
  public let working: [AgentNode]
  public let quiet: [AgentNode]

  public init(
    waiting: [AgentNode] = [],
    working: [AgentNode] = [],
    quiet: [AgentNode] = []
  ) {
    self.waiting = waiting
    self.working = working
    self.quiet = quiet
  }

  public var isEmpty: Bool {
    waiting.isEmpty && working.isEmpty && quiet.isEmpty
  }
}

// MARK: - Tree Building Logic

extension SessionStore {
  /// Builds the current hierarchy tree of agent sessions and ephemeral child processes.
  public func agentTree(now: Date = Date()) -> AgentTree {
    var visited: Set<SessionKey> = []

    let waitingRoots = waiting(now: now)
    let waitingNodes = waitingRoots.map { session in
      buildNode(for: session, visited: &visited, now: now)
    }

    let workingRoots = workingRoots(now: now)
    let workingNodes = workingRoots.map { session in
      buildNode(for: session, visited: &visited, now: now)
    }

    let quietRoots = quiet(now: now)
    let quietNodes = quietRoots.map { session in
      buildNode(for: session, visited: &visited, now: now)
    }

    return AgentTree(waiting: waitingNodes, working: workingNodes, quiet: quietNodes)
  }

  private func workingRoots(now: Date) -> [SessionSnapshot] {
    allSessions
      .filter { session in
        !isChild(session) && session.state == .running
      }
      .sorted { lhs, rhs in
        if lhs.lastActivity != rhs.lastActivity {
          return lhs.lastActivity > rhs.lastActivity
        }
        return lhs.id < rhs.id
      }
  }

  private func buildNode(
    for session: SessionSnapshot,
    visited: inout Set<SessionKey>,
    now: Date
  ) -> AgentNode {
    visited.insert(session.sessionKey)

    let childSessions = allSessions.filter { child in
      guard !visited.contains(child.sessionKey) else { return false }
      guard effectiveParentKey(for: child) == session.sessionKey else { return false }
      if child.state == .finished {
        let age = now.timeIntervalSince(child.lastActivity)
        if age > 10 * 60 {
          return false
        }
      }
      return true
    }

    let childEphemerals = ephemeralChildren.filter { ephemeral in
      ephemeral.parentKey == session.sessionKey
    }

    var childNodes: [AgentNode] = []
    for child in childSessions {
      var branchVisited = visited
      let childNode = buildNode(for: child, visited: &branchVisited, now: now)
      visited.formUnion(branchVisited)
      childNodes.append(childNode)
    }
    for ephemeral in childEphemerals {
      childNodes.append(AgentNode(ephemeral: ephemeral, children: []))
    }

    childNodes.sort { lhs, rhs in
      let lhsWorking = isChildWorking(lhs)
      let rhsWorking = isChildWorking(rhs)
      if lhsWorking != rhsWorking {
        return lhsWorking && !rhsWorking
      }
      let lhsTime = childStartTime(lhs)
      let rhsTime = childStartTime(rhs)
      if lhsTime != rhsTime {
        return lhsTime < rhsTime
      }
      return lhs.id < rhs.id
    }

    return AgentNode(session: session, children: childNodes)
  }

  private func isChildWorking(_ node: AgentNode) -> Bool {
    if node.ephemeral != nil {
      return true
    }
    if let session = node.session {
      return session.state != .finished
    }
    return false
  }

  private func childStartTime(_ node: AgentNode) -> Date {
    if let ephemeral = node.ephemeral {
      return ephemeral.startedAt
    }
    if let session = node.session {
      return startTime(for: session.sessionKey) ?? session.lastActivity
    }
    return .distantPast
  }
}
