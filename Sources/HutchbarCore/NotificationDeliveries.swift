// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Notifications currently shown in Notification Center, one per waiting episode.
/// A shown notification is withdrawn once its session stops waiting or starts a new wait.
public struct NotificationDeliveries: Equatable, Sendable {
  private struct Delivery: Equatable, Sendable {
    let waitingSince: Date
    let id: String
  }

  private var deliveries: [SessionKey: Delivery] = [:]

  public init() {}

  public var isEmpty: Bool { deliveries.isEmpty }

  /// Records a posted notification for the episode `sessionKey` + `waitingSince`.
  public mutating func record(sessionKey: SessionKey, waitingSince: Date, id: String) {
    deliveries[sessionKey] = Delivery(waitingSince: waitingSince, id: id)
  }

  /// Forgets episodes that ended and returns their notification ids to withdraw.
  /// `waiting` maps each session waiting now to the start of its current wait.
  public mutating func expire(waiting: [SessionKey: Date]) -> [String] {
    var ended: [String] = []
    for (sessionKey, delivery) in deliveries where waiting[sessionKey] != delivery.waitingSince {
      ended.append(delivery.id)
      deliveries.removeValue(forKey: sessionKey)
    }
    return ended.sorted()
  }

  /// Forgets everything and returns all ids to withdraw (app shutting down).
  public mutating func removeAll() -> [String] {
    let ids = deliveries.values.map(\.id).sorted()
    deliveries.removeAll()
    return ids
  }
}
