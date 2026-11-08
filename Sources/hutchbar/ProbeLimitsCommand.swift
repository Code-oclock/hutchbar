// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore

/// `hutchbar --probe-limits`: asks every agent profile for its quota once and prints
/// labels, plans and windows (no email, no tokens). Diagnostics for docs/specs/limits-v3.md.
func probeLimits() async {
  let claude = ClaudeUsageProbe()
  for profile in claude.profiles() {
    printProbe("claude", await claude.read(profile, now: Date()))
  }
  guard let codexPath = ExecutableLocator.locate(.codex) else {
    print("codex: executable not found")
    return
  }
  let codex = CodexUsageProbe(
    executable: codexPath, runner: LocalAgentProcessRunner(), appVersion: HutchbarVersion.current)
  for profile in codex.profiles() {
    printProbe("codex", await codex.read(profile, now: Date()))
  }
}

private func printProbe<F: Error>(_ agent: String, _ result: Result<AccountQuota, F>) {
  switch result {
  case .failure(let failure):
    print("\(agent): failed (\(failure))")
  case .success(let quota):
    let plan = quota.plan ?? "?"
    let credits = quota.resetCredits.map { " resets=\($0)" } ?? ""
    print("\(agent) \(quota.accountName) plan=\(plan)\(credits)")
    for window in quota.windows {
      let resets = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "not started"
      let scope = window.scope.map { " [\($0)]" } ?? ""
      print(
        "  \(window.windowMinutes) min\(scope): used \(Int(window.usedPercent)) %, resets \(resets)"
      )
    }
  }
}
