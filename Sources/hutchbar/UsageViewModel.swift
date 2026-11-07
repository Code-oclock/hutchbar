// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import Observation

/// Latest usage ledger from `UsageScanner` plus the period picked in the panel header.
@MainActor
@Observable
final class UsageViewModel {
  var ledger: UsageLedger?
  var period: UsagePeriod = .today

  init(ledger: UsageLedger? = nil) {
    self.ledger = ledger
  }
}
