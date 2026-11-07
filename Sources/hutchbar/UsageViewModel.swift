// SPDX-License-Identifier: GPL-3.0-or-later
import HutchbarCore
import Observation

/// Latest usage ledger from `UsageScanner` plus the period picked in the panel header.
@MainActor
@Observable
final class UsageViewModel {
  var ledger: UsageLedger?
  var period: UsagePeriod {
    didSet {
      onPeriodChange?(period)
    }
  }

  var onPeriodChange: ((UsagePeriod) -> Void)?

  init(ledger: UsageLedger? = nil, period: UsagePeriod = .today) {
    self.ledger = ledger
    self.period = period
  }
}
