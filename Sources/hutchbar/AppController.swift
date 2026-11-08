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
  public let poller: QuotaPoller
  private let coordinator: SourceCoordinator
  private let attention: AttentionPillController

  private var updatesTask: Task<Void, Never>?
  private var pollerTask: Task<Void, Never>?
  private var usageTask: Task<Void, Never>?
  private var timer: Timer?
  private var isStopped = false

  public init(
    settings: Settings = Settings(),
    scanner: UsageScanner = UsageScanner(),
    poller: QuotaPoller? = nil
  ) {
    self.settings = settings
    let store = SessionStore(
      showFinished: settings.showFinished,
      quietAfter: settings.quietAfterSeconds
    )
    self.store = store
    self.scanner = scanner

    let pollerInstance =
      poller
      ?? QuotaPoller(
        targets: QuotaPoller.defaultTargets(appVersion: HutchbarVersion.current)
      )
    self.poller = pollerInstance

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

    settings.onQuietAfterChange = { [weak store] quietAfter in
      store?.quietAfter = quietAfter
    }

    TerminalJumper.pidLookup = { [weak store] session in
      store?.pid(for: session.sessionKey)
    }

    MenuBarController.onPanelVisibilityChange = { [weak pollerInstance, weak self] visible in
      Task {
        await pollerInstance?.setPanelVisible(visible)
      }
      if visible {
        self?.refreshNesting()
      }
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

    let poller = self.poller
    pollerTask = Task { [weak self, poller] in
      await poller.start()
      for await update in poller.updates {
        guard !Task.isCancelled else { break }
        guard let self else { break }
        self.store.apply(update)
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
        self.refreshNesting(now: now)
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

  /// Evaluates process tree nesting and applies results to the store.
  public func refreshNesting(now: Date = Date()) {
    let nesting = ProcessNesting.children(
      sessions: store.allSessions,
      sessionPids: store.trackedPids,
      processes: DarwinProcessTable().allProcesses(),
      now: now
    )
    store.applyNesting(nesting)
  }

  public func stop() {
    guard !isStopped else { return }
    isStopped = true

    MenuBarController.onPanelVisibilityChange = nil

    updatesTask?.cancel()
    updatesTask = nil

    pollerTask?.cancel()
    pollerTask = nil

    usageTask?.cancel()
    usageTask = nil

    timer?.invalidate()
    timer = nil

    TerminalJumper.pidLookup = nil

    attention.stop()

    let coordinator = self.coordinator
    let scanner = self.scanner
    let poller = self.poller
    Task {
      await coordinator.stop()
      await scanner.stop()
      await poller.stop()
    }
  }
}
