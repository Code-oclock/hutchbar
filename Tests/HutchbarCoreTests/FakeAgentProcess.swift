// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

@testable import HutchbarCore

/// Scripted agent CLI: after each line the probe sends, the fake makes the replies
/// registered for that line's first matching key available on stdout.
final class FakeAgentProcessRunner: AgentProcessRunner, @unchecked Sendable {
  struct Reply {
    /// Substring of the sent line that triggers this reply.
    let whenSentContains: String
    let lines: [String]
  }

  private let lock = NSLock()
  private let replies: [Reply]
  private let initialLines: [String]?
  private let launchError: AgentProcessError?
  private var specsStorage: [AgentProcessSpec] = []
  private var sentStorage: [String] = []
  private var closedCount = 0

  init(
    replies: [Reply] = [],
    initialLines: [String]? = nil,
    launchError: AgentProcessError? = nil
  ) {
    self.replies = replies
    self.initialLines = initialLines
    self.launchError = launchError
  }

  var specs: [AgentProcessSpec] { lock.withLock { specsStorage } }
  var sent: [String] { lock.withLock { sentStorage } }
  var closed: Int { lock.withLock { closedCount } }

  func start(_ spec: AgentProcessSpec) async throws -> any AgentProcessSession {
    if let launchError { throw launchError }
    lock.withLock { specsStorage.append(spec) }
    return Session(runner: self)
  }

  fileprivate func record(sent line: String) -> [String] {
    lock.withLock {
      sentStorage.append(line)
      return replies.first { line.contains($0.whenSentContains) }?.lines ?? []
    }
  }

  fileprivate func recordClose() {
    lock.withLock { closedCount += 1 }
  }

  private final class Session: AgentProcessSession, @unchecked Sendable {
    private let runner: FakeAgentProcessRunner
    private let lock = NSLock()
    private var pending: [String]
    private let hasInitial: Bool

    init(runner: FakeAgentProcessRunner) {
      self.runner = runner
      if let initial = runner.initialLines {
        self.pending = initial
        self.hasInitial = true
      } else {
        self.pending = []
        self.hasInitial = false
      }
    }

    func send(_ line: String) async throws {
      let lines = runner.record(sent: line)
      lock.withLock { pending.append(contentsOf: lines) }
    }

    /// Returns queued lines; when none are queued and no initial lines were configured,
    /// the scripted process "hangs", which the fake reports as a timeout so probes exercise that path.
    /// If initial lines were configured, exhaustion indicates stdout closed (returns nil).
    func nextLine() async throws -> String? {
      let (next, initialConfigured): (String?, Bool) = lock.withLock {
        if pending.isEmpty {
          return (nil, hasInitial)
        }
        return (pending.removeFirst(), hasInitial)
      }
      if let next {
        return next
      }
      if initialConfigured {
        return nil
      }
      throw AgentProcessError.timeout
    }

    func close() async {
      runner.recordClose()
    }
  }
}
