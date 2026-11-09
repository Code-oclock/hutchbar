// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - OpenCode Polling

extension SourceCoordinator {
  func pollOpenCodeSessions(now: Date) {
    guard configuration.enabledSources.contains(.openCodeSessions) else { return }
    guard openCodeTracker.shouldScan(now: now, interval: 5.0) else { return }

    let dbPath = (configuration.openCodeDatabasePath as NSString).expandingTildeInPath
    guard let fingerprint = OpenCodeSessionTracker.computeFingerprint(databasePath: dbPath) else {
      return
    }

    guard openCodeTracker.shouldRead(fingerprint: fingerprint, now: now) else {
      return
    }

    let reader = OpenCodeSessionReader(databasePath: dbPath)
    let cutoff = now.addingTimeInterval(-configuration.freshnessWindow)
    guard
      let snapshots = reader.readSessions(
        cutoff: cutoff,
        limit: configuration.maxTrackedFiles,
        now: now
      )
    else {
      return
    }

    openCodeTracker.recordRead(fingerprint: fingerprint, now: now)

    var currentIds: Set<String> = []
    for snapshot in snapshots {
      currentIds.insert(snapshot.id)
      if openCodeTracker.knownSnapshots[snapshot.id] != snapshot {
        openCodeTracker.knownSnapshots[snapshot.id] = snapshot
        yieldUpdate(.session(snapshot))
      }
    }

    var disappearedIds: [String] = []
    for (id, oldSnapshot) in openCodeTracker.knownSnapshots {
      if !currentIds.contains(id) {
        disappearedIds.append(id)
        if oldSnapshot.state != .finished {
          var finished = oldSnapshot
          finished.state = .finished
          finished.waitingSince = nil
          yieldUpdate(.session(finished))
        }
      }
    }

    for id in disappearedIds {
      openCodeTracker.knownSnapshots.removeValue(forKey: id)
    }
  }
}
