// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore
import UserNotifications

/// Protocol abstracting system user notifications.
@MainActor
public protocol UserNotifying: AnyObject, Sendable {
  func requestAuthorization() async -> Bool
  func isAuthorizationDenied() async -> Bool
  func post(_ request: NotificationRequest)
  func removeDelivered(ids: [String])
}

/// UNUserNotificationCenter-backed implementation of UserNotifying.
@MainActor
public final class SystemNotificationCenter: NSObject, UserNotifying,
  UNUserNotificationCenterDelegate
{
  private let center: UNUserNotificationCenter?
  private let onOpenSession: @MainActor (SessionKey) -> Void

  public init(
    center: UNUserNotificationCenter? =
      (Bundle.main.bundleIdentifier != nil
      ? UNUserNotificationCenter.current() : nil),
    onOpenSession: @escaping @MainActor (SessionKey) -> Void
  ) {
    self.center = center
    self.onOpenSession = onOpenSession
    super.init()
    center?.delegate = self
  }

  public func requestAuthorization() async -> Bool {
    guard let center else { return false }
    do {
      return try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      return false
    }
  }

  public func isAuthorizationDenied() async -> Bool {
    guard let center else { return false }
    let settings = await center.notificationSettings()
    return settings.authorizationStatus == .denied
  }

  public func post(_ request: NotificationRequest) {
    guard let center else { return }
    let content = UNMutableNotificationContent()
    content.title = request.title
    content.body = request.body
    content.sound = .default
    content.userInfo = [
      "sessionAgent": request.sessionKey.agent.rawValue,
      "sessionId": request.sessionKey.id,
    ]
    let unRequest = UNNotificationRequest(
      identifier: request.id,
      content: content,
      trigger: nil
    )
    center.add(unRequest) { _ in }
  }

  public func removeDelivered(ids: [String]) {
    guard let center, !ids.isEmpty else { return }
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  @MainActor
  private func handleOpen(sessionKey: SessionKey) {
    onOpenSession(sessionKey)
  }

  nonisolated public func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    let userInfo = response.notification.request.content.userInfo
    guard let agentRaw = userInfo["sessionAgent"] as? String,
      let agent = AgentKind(rawValue: agentRaw),
      let sessionId = userInfo["sessionId"] as? String
    else {
      return
    }
    let sessionKey = SessionKey(agent: agent, id: sessionId)
    await handleOpen(sessionKey: sessionKey)
  }
}

/// Controller coordinating notification policy evaluation and user notification center.
@MainActor
final class NotificationController {
  private let store: SessionStore
  private let settings: Settings
  private let notifier: UserNotifying

  private var policyState = NotificationPolicy.State()
  private var deliveries = NotificationDeliveries()

  init(
    store: SessionStore,
    settings: Settings,
    notifier: UserNotifying? = nil
  ) {
    self.store = store
    self.settings = settings
    let effectiveNotifier =
      notifier
      ?? SystemNotificationCenter { [weak store] sessionKey in
        guard let session = store?.session(for: sessionKey) else { return }
        TerminalJumper.jump(to: session)
      }
    self.notifier = effectiveNotifier

    setupSettingsHooks()
    checkInitialAuthorization()
  }

  private func setupSettingsHooks() {
    settings.onNotificationsChange = { [weak self] enabled in
      guard let self else { return }
      Task {
        if enabled {
          _ = await self.notifier.requestAuthorization()
        }
        let denied = await self.notifier.isAuthorizationDenied()
        self.settings.notificationsDenied = denied
      }
    }

    settings.onCheckNotificationAuthorization = { [weak self] in
      guard let self else { return }
      let denied = await self.notifier.isAuthorizationDenied()
      self.settings.notificationsDenied = denied
    }
  }

  private func checkInitialAuthorization() {
    Task {
      if settings.notifications {
        _ = await notifier.requestAuthorization()
      }
      let denied = await notifier.isAuthorizationDenied()
      settings.notificationsDenied = denied
    }
  }

  func evaluate(now: Date = Date()) {
    let currentWaiting = store.waiting(now: now)

    let currentWaitingBySession = Dictionary(
      currentWaiting.compactMap { session -> (SessionKey, Date)? in
        guard let waitingSince = session.waitingSince else { return nil }
        return (session.sessionKey, waitingSince)
      },
      uniquingKeysWith: { first, _ in first }
    )

    let ended = deliveries.expire(waiting: currentWaitingBySession)
    if !ended.isEmpty {
      notifier.removeDelivered(ids: ended)
    }

    let threshold = settings.notifications ? settings.pillThresholdSeconds : nil
    let decision = NotificationPolicy.decide(
      waiting: currentWaiting,
      now: now,
      threshold: threshold,
      state: policyState,
      language: L10n.currentLanguage()
    )
    policyState = decision.newState

    for request in decision.requests {
      notifier.post(request)
      if let session = currentWaiting.first(where: { $0.sessionKey == request.sessionKey }),
        let waitingSince = session.waitingSince
      {
        deliveries.record(
          sessionKey: request.sessionKey, waitingSince: waitingSince, id: request.id)
      }
    }
  }

  func stop() {
    let shown = deliveries.removeAll()
    if !shown.isEmpty {
      notifier.removeDelivered(ids: shown)
    }
  }

}
