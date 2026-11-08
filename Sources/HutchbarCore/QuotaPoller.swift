// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Failure kinds when probing an agent's account quota limits.
public enum QuotaProbeFailure: Error, Equatable, Sendable {
  case missing
  case needsSignIn
  case outdated
  case unreachable
  case malformed

  public init(_ claudeFailure: ClaudeUsageProbe.Failure) {
    switch claudeFailure {
    case .missing: self = .missing
    case .needsSignIn: self = .needsSignIn
    case .outdated: self = .outdated
    case .unreachable: self = .unreachable
    case .malformed: self = .malformed
    }
  }

  public init(_ codexFailure: CodexUsageProbe.Failure) {
    switch codexFailure {
    case .missing: self = .missing
    case .needsSignIn: self = .needsSignIn
    case .unreachable: self = .unreachable
    case .malformed: self = .malformed
    }
  }
}

/// An individual account quota probe target.
public struct QuotaProbeTarget: Sendable, Identifiable {
  public let id: String
  public let agent: AgentKind
  public let source: SourceKind
  public let initialScheduledAt: Date?
  public let read: @Sendable (Date) async -> Result<AccountQuota, QuotaProbeFailure>

  public init(
    id: String,
    agent: AgentKind,
    source: SourceKind,
    initialScheduledAt: Date? = nil,
    read: @escaping @Sendable (Date) async -> Result<AccountQuota, QuotaProbeFailure>
  ) {
    self.id = id
    self.agent = agent
    self.source = source
    self.initialScheduledAt = initialScheduledAt
    self.read = read
  }
}

/// Coordinates deterministic polling of agent quota targets.
public actor QuotaPoller {
  private struct TargetState: Sendable {
    let target: QuotaProbeTarget
    var nextDue: Date
    var lastSuccessAt: Date?
    var consecutiveUnreachable: Int

    init(
      target: QuotaProbeTarget,
      nextDue: Date,
      lastSuccessAt: Date? = nil,
      consecutiveUnreachable: Int = 0
    ) {
      self.target = target
      self.nextDue = nextDue
      self.lastSuccessAt = lastSuccessAt
      self.consecutiveUnreachable = consecutiveUnreachable
    }
  }

  private let targets: [QuotaProbeTarget]
  private var targetStates: [String: TargetState] = [:]
  private let nowProvider: @Sendable () -> Date
  public private(set) var isPanelVisible = false
  private var sourceAvailability: [SourceKind: Bool] = [:]

  public nonisolated let updates: AsyncStream<SourceUpdate>
  private let continuation: AsyncStream<SourceUpdate>.Continuation

  private var loopTask: Task<Void, Never>?
  private var isPolling = false
  private var isRunning = false
  private var isStopped = false

  public init(
    targets: [QuotaProbeTarget],
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.targets = targets
    self.nowProvider = now

    let currentTime = now()
    var initialStates: [String: TargetState] = [:]
    initialStates.reserveCapacity(targets.count)
    for target in targets {
      let initialDue = target.initialScheduledAt ?? currentTime
      initialStates[target.id] = TargetState(target: target, nextDue: initialDue)
    }
    self.targetStates = initialStates

    let (stream, continuation) = AsyncStream.makeStream(
      of: SourceUpdate.self,
      bufferingPolicy: .bufferingNewest(256)
    )
    self.updates = stream
    self.continuation = continuation
  }

  deinit {
    loopTask?.cancel()
    continuation.finish()
  }

  public func tick() async {
    guard !isStopped, !isPolling else { return }
    let currentTime = nowProvider()

    let dueTargets = targets.compactMap {
      target -> (target: QuotaProbeTarget, state: TargetState)? in
      guard let state = targetStates[target.id], state.nextDue <= currentTime else {
        return nil
      }
      return (target, state)
    }

    guard
      let chosen = dueTargets.min(by: { lhs, rhs in
        lhs.state.nextDue < rhs.state.nextDue
      })
    else {
      return
    }

    isPolling = true
    let chosenTarget = chosen.target
    var chosenState = chosen.state

    let result = await chosenTarget.read(currentTime)
    isPolling = false

    guard !isStopped else { return }

    switch result {
    case .success(let quota):
      chosenState.lastSuccessAt = currentTime
      chosenState.consecutiveUnreachable = 0

      let normalInterval: TimeInterval = isPanelVisible ? 60.0 : 300.0
      let normalDue = currentTime.addingTimeInterval(normalInterval)
      let futureResets = quota.windows.compactMap(\.resetsAt).filter {
        $0 > currentTime && $0 < normalDue
      }

      if let earliestReset = futureResets.min() {
        chosenState.nextDue = earliestReset.addingTimeInterval(60.0)
      } else {
        chosenState.nextDue = normalDue
      }

      targetStates[chosenTarget.id] = chosenState

      if sourceAvailability[chosenTarget.source] != true {
        sourceAvailability[chosenTarget.source] = true
        continuation.yield(.sourceStatus(chosenTarget.source, available: true))
      }
      continuation.yield(.quota(quota))

    case .failure(let failure):
      let delay: TimeInterval
      switch failure {
      case .unreachable:
        delay = unreachableBackoff(attempt: chosenState.consecutiveUnreachable)
        chosenState.consecutiveUnreachable += 1
      case .missing, .needsSignIn, .outdated, .malformed:
        delay = 1800.0
      }

      chosenState.nextDue = currentTime.addingTimeInterval(delay)
      targetStates[chosenTarget.id] = chosenState

      if sourceAvailability[chosenTarget.source] != false {
        sourceAvailability[chosenTarget.source] = false
        continuation.yield(.sourceStatus(chosenTarget.source, available: false))
      }
    }
  }

  public func setPanelVisible(_ visible: Bool) {
    let wasVisible = isPanelVisible
    isPanelVisible = visible
    if visible && !wasVisible {
      let currentTime = nowProvider()
      for target in targets {
        guard var state = targetStates[target.id] else { continue }
        let isOld: Bool
        if let lastSuccess = state.lastSuccessAt {
          isOld = currentTime.timeIntervalSince(lastSuccess) > 60.0
        } else {
          isOld = true
        }
        if isOld {
          state.nextDue = min(state.nextDue, currentTime)
          targetStates[target.id] = state
        }
      }
    }
  }

  public func start() {
    guard !isRunning, !isStopped else { return }
    isRunning = true
    loopTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { break }
        await self.tick()
        let sleepDuration = await self.nextSleepDuration()
        do {
          try await Task.sleep(nanoseconds: UInt64(sleepDuration * 1_000_000_000))
        } catch {
          break
        }
      }
    }
  }

  public func stop() {
    guard !isStopped else { return }
    isStopped = true
    isRunning = false
    loopTask?.cancel()
    loopTask = nil
    continuation.finish()
  }

  public func nextDue(for targetId: String) -> Date? {
    targetStates[targetId]?.nextDue
  }

  public func lastSuccessAt(for targetId: String) -> Date? {
    targetStates[targetId]?.lastSuccessAt
  }

  private func nextSleepDuration() -> TimeInterval {
    let currentTime = nowProvider()
    let earliestDue = targetStates.values.map(\.nextDue).min() ?? currentTime
    let delta = earliestDue.timeIntervalSince(currentTime)
    return max(1.0, min(60.0, delta))
  }

  private func unreachableBackoff(attempt: Int) -> TimeInterval {
    switch attempt {
    case 0: return 300.0
    case 1: return 600.0
    case 2: return 1200.0
    default: return 1800.0
    }
  }
}

extension QuotaPoller {
  public static func defaultTargets(appVersion: String) -> [QuotaProbeTarget] {
    var targets: [QuotaProbeTarget] = []

    let claudeProbe = ClaudeUsageProbe()
    for profile in claudeProbe.profiles() {
      let target = QuotaProbeTarget(
        id: "claude:\(profile.directoryPath)",
        agent: .claudeCode,
        source: .claudeUsage,
        read: { date in
          let result = await claudeProbe.read(profile, now: date)
          return result.mapError { QuotaProbeFailure($0) }
        }
      )
      targets.append(target)
    }

    if let codexPath = ExecutableLocator.locate(.codex) {
      let codexProbe = CodexUsageProbe(
        executable: codexPath,
        runner: LocalAgentProcessRunner(),
        appVersion: appVersion
      )
      for profile in codexProbe.profiles() {
        let target = QuotaProbeTarget(
          id: "codex:\(profile.path)",
          agent: .codex,
          source: .codexUsage,
          read: { date in
            let result = await codexProbe.read(profile, now: date)
            return result.mapError { QuotaProbeFailure($0) }
          }
        )
        targets.append(target)
      }
    }

    return targets
  }

}
