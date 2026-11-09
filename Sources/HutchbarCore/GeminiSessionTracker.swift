// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Fingerprint of a Gemini CLI session file (size and modification time).
public struct GeminiFileFingerprint: Equatable, Sendable {
  public let size: UInt64
  public let mtime: Date

  public init(size: UInt64, mtime: Date) {
    self.size = size
    self.mtime = mtime
  }
}

/// Tracks Gemini CLI session polling state outside of SourceCoordinator.
public final class GeminiSessionTracker: @unchecked Sendable {
  public struct TrackedFileState: Sendable {
    public var fingerprint: GeminiFileFingerprint
    public var lastInactivityCheckTime: Date
    public var sessionId: String

    public init(
      fingerprint: GeminiFileFingerprint, lastInactivityCheckTime: Date, sessionId: String
    ) {
      self.fingerprint = fingerprint
      self.lastInactivityCheckTime = lastInactivityCheckTime
      self.sessionId = sessionId
    }
  }

  public private(set) var lastScanTime: Date = .distantPast
  public private(set) var trackedFiles: [String: TrackedFileState] = [:]
  public var knownSnapshots: [String: SessionSnapshot] = [:]

  public init() {}

  /// Enforces scan rate throttling (e.g. at most once every 5 seconds).
  public func shouldScan(now: Date, interval: TimeInterval = 5.0) -> Bool {
    guard lastScanTime == .distantPast || now.timeIntervalSince(lastScanTime) >= interval else {
      return false
    }
    lastScanTime = now
    return true
  }

  /// Determines whether the file changed compared to the recorded fingerprint.
  public func hasFileChanged(path: String, size: UInt64, mtime: Date) -> Bool {
    guard let tracked = trackedFiles[path] else {
      return true
    }
    return tracked.fingerprint.size != size || tracked.fingerprint.mtime != mtime
  }

  /// Determines whether the 60-second inactivity rule check should run for an unchanged file.
  public func shouldCheckInactivity(
    path: String,
    now: Date,
    interval: TimeInterval = 60.0
  ) -> Bool {
    guard let tracked = trackedFiles[path] else { return false }
    guard now.timeIntervalSince(tracked.lastInactivityCheckTime) >= interval else {
      return false
    }
    trackedFiles[path]?.lastInactivityCheckTime = now
    return true
  }

  /// Records a successful file read and updates the tracked state.
  public func recordRead(
    path: String,
    size: UInt64,
    mtime: Date,
    sessionId: String,
    now: Date
  ) {
    let fingerprint = GeminiFileFingerprint(size: size, mtime: mtime)
    trackedFiles[path] = TrackedFileState(
      fingerprint: fingerprint,
      lastInactivityCheckTime: now,
      sessionId: sessionId
    )
  }

  /// Retrieves the session identifier for a tracked file path.
  public func sessionId(for path: String) -> String? {
    trackedFiles[path]?.sessionId
  }

  /// Removes tracking state for a session that is no longer discovered.
  public func removeTrackedSession(id: String) {
    knownSnapshots.removeValue(forKey: id)
    let matchingPaths = trackedFiles.filter { $0.value.sessionId == id }.map(\.key)
    for path in matchingPaths {
      trackedFiles.removeValue(forKey: path)
    }
  }

  /// Clears tracker state.
  public func reset() {
    lastScanTime = .distantPast
    trackedFiles.removeAll()
    knownSnapshots.removeAll()
  }
}
