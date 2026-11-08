# v0.1 data sources

Status: spec for v0.1. Shared types live in `Sources/HutchbarCore/Models.swift`; every source turns raw input into those types and nothing else.

## Privacy rules (apply to every source)

- Input files contain prompts, code, tool output and possibly secrets. A source extracts only the fields named below. It never stores, logs, prints or puts into errors any other content, including `message.content`, `lastPrompt`, `toolUseResult`, `payload.content`, `last_agent_message`.
- Paths: only the last path component of `cwd` leaves the parser (`projectName`).
- `title` is capped at 80 characters.
- Unknown record types and malformed lines are skipped and counted, never fatal.
- Parsers are pure functions over `JSONLLine` bytes plus a clock. File access goes through `JSONLTailReader` / protocols so tests use fixtures.
- Fixtures are synthetic, written by hand. Real logs are never copied into the repo.

## 1. Claude Code transcripts

Location: `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, appended while the session runs.

Records used (`type` field):
| type | fields used | meaning |
|---|---|---|
| `user` with `message.content` being a string or containing a `text` block, and no `toolUseResult` | `sessionId`, `cwd`, `timestamp` | the human sent a prompt → `running` |
| `user` with `toolUseResult` / `tool_result` content | `timestamp` | a tool finished → `running` |
| `assistant` | `message.stop_reason`, `timestamp`, `cwd` | `tool_use` → `running`; `end_turn` → `waitingForInput` |
| `system` with `subtype: turn_duration` | `timestamp` | turn ended → `waitingForInput` |
| `custom-title` | `customTitle` | session title |
| anything else | `timestamp` if present | only updates `lastActivity` |

`timestamp` is ISO 8601 with fractional seconds. `isSidechain: true` records (subagents) update `lastActivity` but never change the state.

State from transcripts alone: `running` or `waitingForInput`. A session with no record for 30 minutes is `finished`. Waiting for approval cannot be detected reliably from transcripts; it comes from hooks (section 2).

## 2. Claude Code hooks (event files)

Claude Code runs hook commands on events and passes JSON on stdin with `session_id`, `cwd`, `hook_event_name`, plus `notification_type` for `Notification`.

The app binary itself is the hook: `hutchbar --hook` (no AppKit initialisation, no extra runtime such as python3 is required on the user's Mac). It reads stdin (capped at 64 KiB) and appends **one line** to `~/Library/Application Support/hutchbar/events.jsonl` (directory 0700, file 0600, created if missing):

```json
{"v":1,"ts":"2026-11-07T20:00:00Z","session":"<session_id>","event":"<event>"}
```

`event` mapping:
| hook | condition | event |
|---|---|---|
| `Notification` | `notification_type == permission_prompt` | `approval` |
| `Notification` | `notification_type == idle_prompt` | `idle` |
| `Stop` | — | `stop` |
| `UserPromptSubmit` | — | `prompt` |
| `SessionEnd` | — | `end` |

Nothing else is written: no `cwd`, no message, no transcript path. The hook always exits 0 and never blocks Claude Code (writes are best effort, total runtime under 100 ms, file size capped: if the file exceeds 1 MiB it is truncated to empty before appending).

Merge rule: a hook event newer than the last transcript record wins. `approval` → `waitingForApproval` (sets `waitingSince`), `idle`/`stop` → `waitingForInput`, `prompt` → `running`, `end` → `finished`.

Hook events are display-only. hutchbar never approves anything in v0.1, so a forged event can only show a wrong state.

`hutchbar --print-hooks` prints the `hooks` JSON snippet for `~/.claude/settings.json`. hutchbar never edits that file itself.

## 3. Codex sessions

Location: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.

| record | fields used | meaning |
|---|---|---|
| `session_meta` | `payload.id` (fallback `payload.session_id`), `payload.cwd`, `payload.timestamp` | session identity |
| `turn_context` | `payload.cwd` | project |
| `event_msg` / `payload.type == task_started` | record `timestamp` | `running` |
| `event_msg` / `payload.type == task_complete` | record `timestamp` | `waitingForInput` |
| `event_msg` / `payload.type == token_count` | `payload.rate_limits.primary`, `.secondary` (`used_percent`, `window_minutes`, `resets_at` Unix seconds), `payload.rate_limits.plan_type` | quota → `AccountQuota(agent: .codex, accountName: plan_type ?? "codex")` |

The top-level `timestamp` of each record is ISO 8601. Inactive for 30 minutes → `finished`.

## 4. Claude subscription quotas from ccr (optional)

If `~/.local/share/claude-code-router/ccr.db` exists, read it **read-only** (`SQLITE_OPEN_READONLY`, busy timeout 200 ms, `import SQLite3`):

```sql
SELECT account_name, observed_at, five_hour_utilization, five_hour_resets_at,
       seven_day_utilization, seven_day_resets_at
FROM claude_account_quotas;
```

Utilization is a fraction 0...1 → `usedPercent = value * 100`. Timestamps are RFC 3339 text; an empty string means unknown. 5h → `windowMinutes: 300`, 7d → `10080`. A missing file, missing table or locked database means no quotas, never an error shown to the user.

## 5. Aggregation (later slice)

`SessionStore` merges sources by `(agent, id)`, sorts waiting sessions by `waitingSince` (longest first), then running, then by `lastActivity`. Finished sessions older than 24 hours are dropped.
