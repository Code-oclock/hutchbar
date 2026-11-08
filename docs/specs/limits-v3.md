# Limits v3: read quotas from the source

Decisions (2026-11-08): hutchbar is first of all a quota counter plus a live view of sessions (who waits, who works, who called whom). Quotas come from the agent itself, the most exact source available, and work for anyone: a plain terminal, an IDE, the desktop app, with or without ccr. ccr becomes one optional source. Mock-up: `mac-projects-plan/mockup/panel-v3.html` (outside the repo).

Reference: Vorssaint (GPL-3.0-or-later, same licence) does the same in `Services/AgentUsage/AgentClaudeServer.swift`, `AgentCodexServer.swift`, `CodexAccountLimits.swift`, `ClaudeAccountProfile.swift`. Code taken from there keeps its copyright line.

## 1. Model changes (`Models.swift`)

- `QuotaWindow.scope: String?`: `nil` for the general window, otherwise the model family the window is limited to (`"Opus"`, `"Sonnet"`).
- `AccountQuota.source: QuotaSource`: `.agentCLI` (asked the agent itself), `.sessionLog` (a reading the agent wrote into its own log), `.ccr`, `.claudeApp`.
- `AccountQuota.plan: String?`: subscription as the source names it (`pro`, `max`, `plus`, …).
- `AccountQuota.resetCredits: Int?`: free resets available (Codex `rateLimitResetCredits.availableCount`).
- `AccountQuota.accountName` stays the display name; `AccountQuota.id` stays `"<agent>:<accountName>"`.
- New fields have defaults, so existing call sites compile unchanged.

## 2. Running an agent CLI (`AgentProcess.swift`)

`AgentProcessRunner` protocol: start an executable with arguments and an environment, write lines to its stdin, read its stdout line by line, stop it. Tests use a fake that replays scripted stdout lines. `LocalAgentProcessRunner` uses `Foundation.Process` with pipes; stderr is discarded (it may contain content); the child is terminated on timeout or when the conversation ends, and never outlives the call.

`ExecutableLocator`: finds `claude` / `codex` without a login shell (a menu bar app has a minimal `PATH`). Order: `~/.local/bin`, `~/.claude/local` (claude only), `/opt/homebrew/bin`, `/usr/local/bin`, then the newest Node install of fnm, nvm, asdf, mise, volta, bun, pnpm, `~/.npm-global/bin`. First executable regular file wins.

Environment for the child: start empty; copy `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG`, `LC_*`, `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY` (and lower-case forms), `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`; `PATH` = the executable's directory + `/usr/bin:/bin:/usr/sbin:/sbin`. Never pass `ANTHROPIC_*`, `CLAUDE_*` (except the chosen `CLAUDE_CONFIG_DIR`), `CLAUDECODE`, `OPENAI_*`, `CODEX_*` (except the chosen `CODEX_HOME`). Claude also gets `DISABLE_AUTOUPDATER=1`.

## 3. Claude Code (`ClaudeUsageProbe.swift`)

Profiles: the default one (`~/.claude` with `~/.claude.json`; `CLAUDE_CONFIG_DIR` is **not** set, so Claude uses its normal Keychain entry) plus every directory `~/.claude-*` (at most 8) that contains `.claude.json`; for those `CLAUDE_CONFIG_DIR` is set. A profile directory must be owned by the user and not group/world-writable.

Command (no model request, no tool, no MCP server, no user hook runs; spends no tokens):
```
claude --print --input-format stream-json --output-format stream-json --verbose
  --no-session-persistence --tools "" --strict-mcp-config --mcp-config {"mcpServers":{}}
  --setting-sources "" --settings {"disableAllHooks":true}
```
stdin, one JSON per line:
1. `{"type":"control_request","request_id":"initialize","request":{"subtype":"initialize"}}` → wait for `control_response` with `response.request_id == "initialize"`.
2. `{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}` → `control_response` with `response.request_id == "usage"`; payload in `response.response`.

Payload (verified live with Claude Code 2.1.319): `subscription_type` (`"pro"`), `rate_limits_available` (bool), `rate_limits`:
- preferred: `rate_limits.limits[]` with `kind`, `group` (`session` → 300 min, `weekly` → 10080 min), `percent` (0…100 used), `resets_at` (ISO 8601 or null), `scope` (null or a model family), `is_active`;
- fallback when `limits` is absent: keys `five_hour`, `seven_day`, `seven_day_opus` (scope Opus), `seven_day_sonnet` (scope Sonnet), each `{utilization, resets_at}`; `null` keys are skipped.
- `resets_at == null` means the window has not started (nothing used yet): keep the window with `resetsAt = nil`.

Result: `AccountQuota(agent: .claudeCode, accountName: <label>, windows, observedAt: now, source: .agentCLI, plan: subscription_type)`. Label: the part of `oauthAccount.emailAddress` before `@` from the profile's `.claude.json`, else the directory name. The email itself is never stored or logged; only the label is kept.

Failures (`ClaudeUsageProbe.Failure`): `.missing` (no executable), `.needsSignIn` (`rate_limits_available != true`, or an error mentioning auth/login), `.outdated` (unknown control request), `.unreachable` (timeout 25 s, process died, or the answer is Claude's cached copy: `.claude.json` `cachedUsageUtilization.fetchedAtMs` older than 60 s at the moment of the request), `.malformed`. Claude saves the new copy only after it has answered, so a stale-looking copy is re-read for up to 2 s before the answer counts as offline (seen live: without the wait every request made more than 60 s after the previous one failed).

## 4. Codex (`CodexUsageProbe.swift`)

Profiles: `~/.codex` and `~/.codex-*` (at most 8) that contain `auth.json`; `CODEX_HOME` is set to the directory for every profile except the default.

Command: `codex -c features.plugins=false app-server`, JSON-RPC 2.0 over stdio, one JSON per line:
1. `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"hutchbar","title":"hutchbar","version":<app version>},"capabilities":null}}` → result with `id 1`.
2. `{"method":"initialized"}` (notification, no answer).
3. `{"id":2,"method":"account/read","params":{"refreshToken":false}}` → `result.account.type == "chatgpt"` required (else `.needsSignIn`), `result.account.planType` → plan. `email` is read only to build the label (part before `@`), never stored.
4. `{"id":3,"method":"account/rateLimits/read","params":{}}` → `result.rateLimitsByLimitId.codex` or `result.rateLimits`: `primary` / `secondary` each `{usedPercent, windowDurationMins, resetsAt (unix seconds)}`; `rateLimitResetCredits.availableCount` → `resetCredits`.
Notifications and unrelated ids are ignored. Timeout 25 s.

Verified live with codex-cli 0.162.1.

## 5. Polling (`QuotaPoller.swift`, next step)

- One probe at a time, never two processes in parallel.
- Every 5 min in the background; every 60 s while the panel is open; 60 s after a known `resetsAt` passes.
- Failures: `.unreachable` → retry after 5, 10, 20, 30 min; `.missing`, `.needsSignIn`, `.outdated` → 30 min.
- Codex readings from session logs (`token_count.rate_limits`, already parsed) keep arriving in between; the newest `observedAt` per account wins.
- ccr stays a source for users whose accounts live in ccr. A ccr account and a CLI account are the same account when their weekly `resetsAt` match to the minute; then they are shown once, under the ccr name.

## 6. Presentation rules

- A window whose `resetsAt` is in the past has restarted: show it as fully available with "updates on next request", never as "no fresh data".
- `resetsAt == nil` with 0 % used: "not started".
- All accounts of a provider are shown; the one with the newest activity is marked "now".
