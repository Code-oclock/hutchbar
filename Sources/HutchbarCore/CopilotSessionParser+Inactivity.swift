// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Inactivity Helpers

extension CopilotSessionParser {
  public static func isInactive(
    lastActivity: Date,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> Bool {
    now.timeIntervalSince(lastActivity) >= timeout
  }

  public static func applyInactivityTimeout(
    to snapshot: SessionSnapshot,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot {
    guard snapshot.state != .finished,
      isInactive(lastActivity: snapshot.lastActivity, now: now, timeout: timeout)
    else {
      return snapshot
    }
    var updated = snapshot
    updated.state = .finished
    updated.waitingSince = nil
    return updated
  }

  public static func applyInactivityTimeout(
    to optionalSnapshot: SessionSnapshot?,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot? {
    guard let snapshot = optionalSnapshot else { return nil }
    let updated: SessionSnapshot = applyInactivityTimeout(to: snapshot, now: now, timeout: timeout)
    return updated
  }

  public static func applyInactivityRule(
    to snapshot: SessionSnapshot,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot {
    applyInactivityTimeout(to: snapshot, now: now, timeout: timeout)
  }

  public static func applyInactivityRule(
    to optionalSnapshot: SessionSnapshot?,
    now: Date,
    timeout: TimeInterval = inactivityTimeout
  ) -> SessionSnapshot? {
    applyInactivityTimeout(to: optionalSnapshot, now: now, timeout: timeout)
  }
}
