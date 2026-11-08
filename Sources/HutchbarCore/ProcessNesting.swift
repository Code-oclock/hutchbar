// SPDX-License-Identifier: GPL-3.0-or-later
import Darwin
import Foundation

/// Ephemeral child process discovered in the system process table.
public struct EphemeralChild: Equatable, Sendable, Identifiable {
  public let id: String
  public let parentKey: SessionKey
  public let executableName: String
  public let displayName: String
  public let startedAt: Date

  public init(
    id: String,
    parentKey: SessionKey,
    executableName: String,
    displayName: String,
    startedAt: Date
  ) {
    self.id = id
    self.parentKey = parentKey
    self.executableName = executableName
    self.displayName = displayName
    self.startedAt = startedAt
  }
}

/// Result of evaluating the process nesting hierarchy.
public struct ProcessNestingResult: Equatable, Sendable {
  public let parentByChild: [SessionKey: SessionKey]
  public let ephemeral: [EphemeralChild]

  public init(parentByChild: [SessionKey: SessionKey], ephemeral: [EphemeralChild]) {
    self.parentByChild = parentByChild
    self.ephemeral = ephemeral
  }
}

/// Pure functions for calculating process hierarchy nesting between agent sessions.
public enum ProcessNesting {
  public static let maxAncestorSteps = 64

  public static let agentNames: Set<String> = [
    "claude",
    "codex",
    "agy",
    "gemini",
    "qwen",
    "opencode",
    "cursor-agent",
    "copilot",
    "amp",
    "droid",
    "aider",
  ]

  /// Formats user-facing display name for an agent executable.
  public static func formatDisplayName(for executableName: String) -> String {
    if executableName == "agy" {
      return "Flash (agy)"
    }
    return executableName
  }

  /// Calculates nested children relationships across tracked sessions and processes.
  public static func children(
    sessions: [SessionSnapshot],
    sessionPids: [SessionKey: Int32],
    processes: [ProcessInfoLite],
    now: Date
  ) -> ProcessNestingResult {
    var sessionByPid: [pid_t: SessionKey] = [:]
    sessionByPid.reserveCapacity(sessionPids.count)
    for (key, pid) in sessionPids {
      sessionByPid[pid] = key
    }

    matchCodexSessionsWithoutPid(
      sessions: sessions,
      sessionPids: sessionPids,
      processes: processes,
      into: &sessionByPid
    )

    var processMap: [pid_t: ProcessInfoLite] = [:]
    processMap.reserveCapacity(processes.count)
    for proc in processes {
      processMap[proc.pid] = proc
    }

    var parentByChild: [SessionKey: SessionKey] = [:]
    var ephemeralList: [EphemeralChild] = []

    // Pids that are ancestors of a tracked session's process (e.g. a `codex` node
    // wrapper around the native `codex`): never shown as ephemeral rows.
    let sessionAncestors = ancestorPids(of: Array(sessionByPid.keys), processMap: processMap)

    for proc in processes {
      let baseName = URL(fileURLWithPath: proc.executableName).lastPathComponent
      guard agentNames.contains(baseName) else { continue }

      guard
        let found = findAncestorSession(
          startPid: proc.ppid,
          processPid: proc.pid,
          sessionByPid: sessionByPid,
          processMap: processMap
        )
      else {
        continue
      }
      let parentKey = found.key

      let thisSessionKey = sessionByPid[proc.pid]
      if let thisSessionKey {
        // A session cannot be a child of itself.
        if thisSessionKey != parentKey {
          parentByChild[thisSessionKey] = parentKey
        }
      } else {
        // Part of another agent's own process tree (e.g. `agy` wrapper → `agy`): skip.
        if found.passedAgent || sessionAncestors.contains(proc.pid) { continue }
        let displayName = formatDisplayName(for: baseName)
        ephemeralList.append(
          EphemeralChild(
            id: "proc:\(proc.pid)",
            parentKey: parentKey,
            executableName: baseName,
            displayName: displayName,
            startedAt: proc.startTime
          )
        )
      }
    }

    ephemeralList.sort { first, second in
      if first.startedAt != second.startedAt {
        return first.startedAt < second.startedAt
      }
      return first.id < second.id
    }

    return ProcessNestingResult(parentByChild: parentByChild, ephemeral: ephemeralList)
  }

  private static func matchCodexSessionsWithoutPid(
    sessions: [SessionSnapshot],
    sessionPids: [SessionKey: Int32],
    processes: [ProcessInfoLite],
    into sessionByPid: inout [pid_t: SessionKey]
  ) {
    let codexWithoutPid = sessions.filter {
      $0.agent == .codex && sessionPids[$0.sessionKey] == nil && ($0.cwd?.isEmpty == false)
    }

    for session in codexWithoutPid {
      guard let sessionCwd = session.cwd else { continue }
      let targetPath = AgentLocator.canonicalizePath(sessionCwd)
      let candidates = processes.filter { proc in
        guard isCodexProcess(proc.executableName) else { return false }
        guard sessionByPid[proc.pid] == nil else { return false }
        guard let procCwd = proc.cwd, !procCwd.isEmpty else { return false }
        return AgentLocator.canonicalizePath(procCwd) == targetPath
      }
      if let chosen = candidates.max(by: { lhs, rhs in
        if lhs.startTime != rhs.startTime {
          return lhs.startTime < rhs.startTime
        }
        return lhs.pid < rhs.pid
      }) {
        sessionByPid[chosen.pid] = session.sessionKey
      }
    }
  }

  /// Walks up from `startPid`; returns the first tracked session found and whether an
  /// untracked agent process was passed on the way.
  private static func findAncestorSession(
    startPid: pid_t,
    processPid: pid_t,
    sessionByPid: [pid_t: SessionKey],
    processMap: [pid_t: ProcessInfoLite]
  ) -> (key: SessionKey, passedAgent: Bool)? {
    var currentPid = startPid
    var visited: Set<pid_t> = [processPid]
    var steps = 0
    var passedAgent = false

    while currentPid > 1 && steps < maxAncestorSteps && !visited.contains(currentPid) {
      visited.insert(currentPid)
      steps += 1
      if let parentKey = sessionByPid[currentPid] {
        return (parentKey, passedAgent)
      }
      guard let parentProc = processMap[currentPid] else {
        break
      }
      if agentNames.contains(URL(fileURLWithPath: parentProc.executableName).lastPathComponent) {
        passedAgent = true
      }
      currentPid = parentProc.ppid
    }
    return nil
  }

  private static func ancestorPids(
    of pids: [pid_t], processMap: [pid_t: ProcessInfoLite]
  ) -> Set<pid_t> {
    var result: Set<pid_t> = []
    for pid in pids {
      var current = processMap[pid]?.ppid ?? 0
      var steps = 0
      while current > 1 && steps < maxAncestorSteps && !result.contains(current) {
        result.insert(current)
        steps += 1
        current = processMap[current]?.ppid ?? 0
      }
    }
    return result
  }

  private static func isCodexProcess(_ name: String) -> Bool {
    URL(fileURLWithPath: name).lastPathComponent == "codex"
  }
}
