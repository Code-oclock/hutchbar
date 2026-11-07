// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import HutchbarCore

@Suite("StatusIconModelTests")
struct StatusIconModelTests {
  @Test func waitingCountFormatting() {
    #expect(StatusIconModel(waitingCount: 0, quotaPercent: nil).text == nil)
    #expect(StatusIconModel(waitingCount: -1, quotaPercent: nil).text == nil)
    #expect(StatusIconModel(waitingCount: 1, quotaPercent: nil).text == "1")
    #expect(StatusIconModel(waitingCount: 9, quotaPercent: nil).text == "9")
    #expect(StatusIconModel(waitingCount: 42, quotaPercent: nil).text == "42")
  }

  @Test func ringLevelThresholds() {
    #expect(StatusIconModel.evaluateRingLevel(nil) == .normal)
    #expect(StatusIconModel.evaluateRingLevel(0.0) == .normal)
    #expect(StatusIconModel.evaluateRingLevel(50.0) == .normal)
    #expect(StatusIconModel.evaluateRingLevel(79.9) == .normal)
    #expect(StatusIconModel.evaluateRingLevel(80.0) == .warning)
    #expect(StatusIconModel.evaluateRingLevel(85.0) == .warning)
    #expect(StatusIconModel.evaluateRingLevel(94.99) == .warning)
    #expect(StatusIconModel.evaluateRingLevel(95.0) == .critical)
    #expect(StatusIconModel.evaluateRingLevel(99.0) == .critical)
    #expect(StatusIconModel.evaluateRingLevel(100.0) == .critical)
  }

  @Test func combinedModelInitialization() {
    let modelWithoutQuota = StatusIconModel(waitingCount: 2, quotaPercent: nil)
    #expect(modelWithoutQuota.text == "2")
    #expect(modelWithoutQuota.ringPercent == nil)
    #expect(modelWithoutQuota.ringLevel == .normal)

    let modelWithWarningQuota = StatusIconModel(waitingCount: 0, quotaPercent: 82.5)
    #expect(modelWithWarningQuota.text == nil)
    #expect(modelWithWarningQuota.ringPercent == 82.5)
    #expect(modelWithWarningQuota.ringLevel == .warning)

    let modelWithCriticalQuota = StatusIconModel(waitingCount: 3, quotaPercent: 96.0)
    #expect(modelWithCriticalQuota.text == "3")
    #expect(modelWithCriticalQuota.ringPercent == 96.0)
    #expect(modelWithCriticalQuota.ringLevel == .critical)
  }
}
