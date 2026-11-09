// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

private let notificationDeliveriesStart = Date(timeIntervalSince1970: 1_731_150_000)
private let notificationDeliveriesKey = SessionKey(agent: .claudeCode, id: "s1")

@Test func notificationDeliveries_stillWaitingKeepsNotification() {
  var deliveries = NotificationDeliveries()
  deliveries.record(
    sessionKey: notificationDeliveriesKey, waitingSince: notificationDeliveriesStart, id: "n1")
  #expect(
    deliveries.expire(waiting: [notificationDeliveriesKey: notificationDeliveriesStart]).isEmpty)
  #expect(!deliveries.isEmpty)
}

@Test func notificationDeliveries_stoppedWaitingWithdrawsOnce() {
  var deliveries = NotificationDeliveries()
  deliveries.record(
    sessionKey: notificationDeliveriesKey, waitingSince: notificationDeliveriesStart, id: "n1")
  #expect(deliveries.expire(waiting: [:]) == ["n1"])
  #expect(deliveries.expire(waiting: [:]).isEmpty)
  #expect(deliveries.isEmpty)
}

@Test func notificationDeliveries_newWaitWithdrawsTheOldOne() {
  var deliveries = NotificationDeliveries()
  deliveries.record(
    sessionKey: notificationDeliveriesKey, waitingSince: notificationDeliveriesStart, id: "n1")
  let later = notificationDeliveriesStart.addingTimeInterval(600)
  #expect(deliveries.expire(waiting: [notificationDeliveriesKey: later]) == ["n1"])
}

@Test func notificationDeliveries_removeAllReturnsEverything() {
  var deliveries = NotificationDeliveries()
  deliveries.record(
    sessionKey: notificationDeliveriesKey, waitingSince: notificationDeliveriesStart, id: "n1")
  deliveries.record(
    sessionKey: SessionKey(agent: .codex, id: "s2"), waitingSince: notificationDeliveriesStart,
    id: "n2")
  #expect(deliveries.removeAll() == ["n1", "n2"])
  #expect(deliveries.isEmpty)
}
