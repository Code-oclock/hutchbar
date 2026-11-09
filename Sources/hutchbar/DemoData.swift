// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import HutchbarCore

/// Populates deterministic demo data for screenshot rendering (`--render-panel <png> --demo`).
@MainActor
enum DemoData {
  /// Populates the session store with mock sessions and quotas, and returns a mock usage ledger.
  static func populate(store: SessionStore, now: Date) -> UsageLedger {
    populateSourceStatuses(store: store, now: now)
    populateWaitingSessions(store: store, now: now)
    populateWorkingSessions(store: store, now: now)
    populateQuotas(store: store, now: now)
    return buildUsageLedger(now: now)
  }

  private static func populateSourceStatuses(store: SessionStore, now: Date) {
    store.apply(.sourceStatus(.claudeTranscripts, available: true), now: now)
    store.apply(.sourceStatus(.claudeHooks, available: true), now: now)
    store.apply(.sourceStatus(.codexSessions, available: true), now: now)
    store.apply(.sourceStatus(.claudeUsage, available: true), now: now)
    store.apply(.sourceStatus(.codexUsage, available: true), now: now)
    store.apply(.sourceStatus(.antigravityUsage, available: true), now: now)
    store.apply(.sourceStatus(.copilotUsage, available: true), now: now)
    store.apply(.sourceStatus(.geminiSessions, available: true), now: now)
  }
}

// MARK: - Sessions

extension DemoData {
  fileprivate static func populateWaitingSessions(store: SessionStore, now: Date) {
    let claudeApproval = SessionSnapshot(
      id: "demo-claude-billing",
      agent: .claudeCode,
      state: .waitingForApproval,
      projectName: "billing-api",
      title: "migrate payments to v2",
      lastActivity: now.addingTimeInterval(-2 * 60),
      waitingSince: now.addingTimeInterval(-2 * 60)
    )
    store.apply(.session(claudeApproval), now: now)

    let codexTurn = SessionSnapshot(
      id: "demo-codex-mobile",
      agent: .codex,
      state: .waitingForInput,
      projectName: "mobile-app",
      title: "egress e2e",
      lastActivity: now.addingTimeInterval(-7 * 60),
      waitingSince: now.addingTimeInterval(-7 * 60)
    )
    store.apply(.session(codexTurn), now: now)

    let quietClaude = SessionSnapshot(
      id: "demo-claude-auth",
      agent: .claudeCode,
      state: .waitingForInput,
      projectName: "auth-service",
      title: "cleanup tokens",
      lastActivity: now.addingTimeInterval(-75 * 60),
      waitingSince: now.addingTimeInterval(-75 * 60)
    )
    store.apply(.session(quietClaude), now: now)

    let quietCodex = SessionSnapshot(
      id: "demo-codex-infra",
      agent: .codex,
      state: .waitingForInput,
      projectName: "infra-deploy",
      title: "k8s manifests",
      lastActivity: now.addingTimeInterval(-120 * 60),
      waitingSince: now.addingTimeInterval(-120 * 60)
    )
    store.apply(.session(quietCodex), now: now)
  }

  fileprivate static func populateWorkingSessions(store: SessionStore, now: Date) {
    let docsId = "demo-claude-docs"
    let docsKey = SessionKey(agent: .claudeCode, id: docsId)

    let claudeDocs = SessionSnapshot(
      id: docsId,
      agent: .claudeCode,
      state: .running,
      projectName: "docs-site",
      title: "write release notes",
      lastActivity: now
    )
    store.apply(.session(claudeDocs), now: now)

    let agyChild = SessionSnapshot(
      id: "demo-agy-flash",
      agent: .antigravity,
      state: .running,
      projectName: "docs-site",
      title: "Flash",
      lastActivity: now,
      parentKey: docsKey,
      childKind: .process
    )
    store.apply(.session(agyChild), now: now)

    let subagentChild = SessionSnapshot(
      id: "demo-claude-explore",
      agent: .claudeCode,
      state: .finished,
      projectName: "docs-site",
      title: "Explore: find adapters",
      lastActivity: now.addingTimeInterval(-2 * 60),
      parentKey: docsKey,
      childKind: .subagent
    )
    store.apply(.session(subagentChild), now: now)

    let geminiPipeline = SessionSnapshot(
      id: "demo-gemini-pipeline",
      agent: .geminiCLI,
      state: .running,
      projectName: "data-pipeline",
      lastActivity: now.addingTimeInterval(-60)
    )
    store.apply(.session(geminiPipeline), now: now)

    store.applyNesting(ProcessNestingResult(parentByChild: [:], ephemeral: []))
  }
}

// MARK: - Quotas

extension DemoData {
  fileprivate static func populateQuotas(store: SessionStore, now: Date) {
    populateClaudeQuotas(store: store, now: now)
    populateCodexQuotas(store: store, now: now)
    populateAntigravityQuotas(store: store, now: now)
    populateCopilotQuotas(store: store, now: now)
  }

  private static func populateClaudeQuotas(store: SessionStore, now: Date) {
    let directWindows = [
      QuotaWindow(
        windowMinutes: 300,
        usedPercent: 38.0,
        resetsAt: now.addingTimeInterval(3 * 3600 + 15 * 60)
      ),
      QuotaWindow(
        windowMinutes: 10080,
        usedPercent: 59.0,
        resetsAt: now.addingTimeInterval(4 * 86400 + 6 * 3600)
      ),
    ]
    let claudeDirect = AccountQuota(
      agent: .claudeCode,
      accountName: "alex@example.com",
      windows: directWindows,
      observedAt: now,
      source: .sessionLog,
      plan: "Max"
    )
    store.apply(.quota(claudeDirect), now: now)

    let team1Windows = [
      QuotaWindow(
        windowMinutes: 10080,
        usedPercent: 12.0,
        resetsAt: now.addingTimeInterval(5 * 86400 + 2 * 3600)
      )
    ]
    let ccrTeam1 = AccountQuota(
      agent: .claudeCode,
      accountName: "team-1",
      windows: team1Windows,
      observedAt: now.addingTimeInterval(-300),
      source: .ccr
    )
    store.apply(.quota(ccrTeam1), now: now)

    let team2Windows = [
      QuotaWindow(
        windowMinutes: 10080,
        usedPercent: 88.0,
        resetsAt: now.addingTimeInterval(2 * 86400 + 14 * 3600)
      )
    ]
    let ccrTeam2 = AccountQuota(
      agent: .claudeCode,
      accountName: "team-2",
      windows: team2Windows,
      observedAt: now.addingTimeInterval(-600),
      source: .ccr
    )
    store.apply(.quota(ccrTeam2), now: now)
  }

  private static func populateCodexQuotas(store: SessionStore, now: Date) {
    let codexWindows = [
      QuotaWindow(
        windowMinutes: 300,
        usedPercent: 36.0,
        resetsAt: now.addingTimeInterval(2 * 3600 + 45 * 60)
      ),
      QuotaWindow(
        windowMinutes: 10080,
        usedPercent: 47.0,
        resetsAt: now.addingTimeInterval(3 * 86400 + 18 * 3600)
      ),
    ]
    let codexQuota = AccountQuota(
      agent: .codex,
      accountName: "alex@example.com",
      windows: codexWindows,
      observedAt: now,
      source: .agentCLI,
      plan: "Plus"
    )
    store.apply(.quota(codexQuota), now: now)
  }

  private static func populateAntigravityQuotas(store: SessionStore, now: Date) {
    let agyWindows = [
      QuotaWindow(
        windowMinutes: 300,
        usedPercent: 4.0,
        resetsAt: now.addingTimeInterval(4 * 3600 + 30 * 60),
        scope: "Gemini"
      ),
      QuotaWindow(
        windowMinutes: 10080,
        usedPercent: 21.0,
        resetsAt: now.addingTimeInterval(5 * 86400 + 12 * 3600),
        scope: "Gemini"
      ),
      QuotaWindow(
        windowMinutes: 10080,
        usedPercent: 30.0,
        resetsAt: now.addingTimeInterval(3 * 86400 + 8 * 3600),
        scope: "Claude+GPT"
      ),
    ]
    let agyQuota = AccountQuota(
      agent: .antigravity,
      accountName: "agy",
      windows: agyWindows,
      observedAt: now,
      source: .agentCLI
    )
    store.apply(.quota(agyQuota), now: now)
  }

  private static func populateCopilotQuotas(store: SessionStore, now: Date) {
    let copilotWindows = [
      QuotaWindow(
        windowMinutes: 43200,
        usedPercent: 29.0,
        resetsAt: now.addingTimeInterval(18 * 86400)
      )
    ]
    let copilotQuota = AccountQuota(
      agent: .copilot,
      accountName: "alex",
      windows: copilotWindows,
      observedAt: now,
      source: .serviceAPI,
      plan: "Pro"
    )
    store.apply(.quota(copilotQuota), now: now)
  }
}

// MARK: - Usage Ledger

extension DemoData {
  fileprivate static func buildUsageLedger(now: Date) -> UsageLedger {
    var ledger = UsageLedger()
    let calendar = Calendar.current
    let dayDate = calendar.startOfDay(for: now)

    recordClaudeUsage(into: &ledger, day: dayDate)
    recordCodexUsage(into: &ledger, day: dayDate)
    recordGeminiUsage(into: &ledger, day: dayDate)

    return ledger
  }

  private static func recordClaudeUsage(into ledger: inout UsageLedger, day: Date) {
    ledger.record(
      UsageEvent(
        provider: .claudeCode,
        model: "claude-opus-4-6",
        day: day,
        hour: 10,
        tokens: TokenUsage(input: 200_000, output: 300_000, cacheRead: 100_000)
      )
    )
    ledger.record(
      UsageEvent(
        provider: .claudeCode,
        model: "claude-opus-4-6",
        day: day,
        hour: 14,
        tokens: TokenUsage(input: 200_000, output: 300_000, cacheRead: 100_000)
      )
    )

    ledger.record(
      UsageEvent(
        provider: .claudeCode,
        model: "claude-sonnet-4-5",
        day: day,
        hour: 9,
        tokens: TokenUsage(input: 300_000, output: 100_000, cacheRead: 400_000)
      )
    )
    ledger.record(
      UsageEvent(
        provider: .claudeCode,
        model: "claude-sonnet-4-5",
        day: day,
        hour: 11,
        tokens: TokenUsage(input: 400_000, output: 150_000, cacheRead: 500_000)
      )
    )
    ledger.record(
      UsageEvent(
        provider: .claudeCode,
        model: "claude-sonnet-4-5",
        day: day,
        hour: 15,
        tokens: TokenUsage(input: 450_000, output: 180_000, cacheRead: 600_000)
      )
    )
    ledger.record(
      UsageEvent(
        provider: .claudeCode,
        model: "claude-sonnet-4-5",
        day: day,
        hour: 16,
        tokens: TokenUsage(input: 100_000, output: 30_000, cacheRead: 200_000)
      )
    )
  }

  private static func recordCodexUsage(into ledger: inout UsageLedger, day: Date) {
    ledger.record(
      UsageEvent(
        provider: .codex,
        model: "gpt-5.2-codex",
        day: day,
        hour: 10,
        tokens: TokenUsage(input: 200_000, output: 70_000, cacheRead: 300_000)
      )
    )
    ledger.record(
      UsageEvent(
        provider: .codex,
        model: "gpt-5.2-codex",
        day: day,
        hour: 14,
        tokens: TokenUsage(input: 150_000, output: 60_000, cacheRead: 200_000)
      )
    )
    ledger.record(
      UsageEvent(
        provider: .codex,
        model: "gpt-5.2-codex",
        day: day,
        hour: 16,
        tokens: TokenUsage(input: 80_000, output: 20_000, cacheRead: 100_000)
      )
    )
  }

  private static func recordGeminiUsage(into ledger: inout UsageLedger, day: Date) {
    ledger.record(
      UsageEvent(
        provider: .geminiCLI,
        model: "gemini-2.5-flash",
        day: day,
        hour: 11,
        tokens: TokenUsage(input: 50_000, output: 20_000, cacheRead: 50_000)
      ),
      cost: 0.15
    )
    ledger.record(
      UsageEvent(
        provider: .geminiCLI,
        model: "gemini-2.5-flash",
        day: day,
        hour: 15,
        tokens: TokenUsage(input: 40_000, output: 15_000, cacheRead: 30_000)
      ),
      cost: 0.10
    )
  }
}
