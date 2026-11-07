// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore

/// Coordinates the session store, background file log tracking, and attention alerts.
@MainActor
final class AppController {
  public let store: SessionStore
  public let scanner: UsageScanner
  public let usage: UsageViewModel
  public let settings: Settings
  private let coordinator: SourceCoordinator
  private let attention: AttentionPillController

  private var updatesTask: Task<Void, Never>?
  private var usageTask: Task<Void, Never>?
  private var timer: Timer?
  private var isStopped = false

  public init(
    settings: Settings = Settings(),
    scanner: UsageScanner = UsageScanner()
  ) {
    self.settings = settings
    let store = SessionStore(showFinished: settings.showFinished)
    self.store = store
    self.scanner = scanner

    let usage = UsageViewModel(period: settings.usagePeriod)
    usage.onPeriodChange = { [weak settings] period in
      settings?.usagePeriod = period
    }
    settings.onUsagePeriodChange = { [weak usage] period in
      if usage?.period != period {
        usage?.period = period
      }
    }
    self.usage = usage

    var config = SourceCoordinator.Configuration()
    config.enabledSources = settings.enabledSources
    let coordinator = SourceCoordinator(configuration: config)
    self.coordinator = coordinator

    self.attention = AttentionPillController(store: store) { session in
      TerminalJumper.jump(to: session)
    }

    settings.onShowFinishedChange = { [weak store] show in
      store?.showFinished = show
    }

    start()
  }

  public func start() {
    guard !isStopped, updatesTask == nil else { return }

    let coordinator = self.coordinator
    updatesTask = Task { [weak self, coordinator] in
      await coordinator.start()
      for await update in coordinator.updates {
        guard !Task.isCancelled else { break }
        guard let self else { break }
        self.store.apply(update)
        self.attention.evaluate(
          now: Date(),
          thresholdSeconds: self.settings.pillThresholdSeconds
        )
      }
    }

    let scanner = self.scanner
    usageTask = Task { [weak self, scanner] in
      await scanner.start()
      for await ledger in scanner.snapshots {
        guard !Task.isCancelled else { break }
        guard let self else { break }
        self.usage.ledger = ledger
      }
    }

    let scheduledTimer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !self.isStopped else { return }
        let now = Date()
        self.store.prune(now: now)
        self.attention.evaluate(
          now: now,
          thresholdSeconds: self.settings.pillThresholdSeconds
        )
      }
    }
    RunLoop.main.add(scheduledTimer, forMode: .common)
    self.timer = scheduledTimer
  }

  public func stop() {
    guard !isStopped else { return }
    isStopped = true

    updatesTask?.cancel()
    updatesTask = nil

    usageTask?.cancel()
    usageTask = nil

    timer?.invalidate()
    timer = nil

    attention.stop()

    let coordinator = self.coordinator
    let scanner = self.scanner
    Task {
      await coordinator.stop()
      await scanner.stop()
    }
  }
}
