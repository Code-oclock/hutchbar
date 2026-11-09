# Privacy

hutchbar runs on your Mac and sends nothing about you or your agents anywhere. There is
no telemetry, analytics, advertising, remote logging or crash upload. This page lists
everything it reads, runs, writes and connects to.

## What it reads

Agent logs and databases are untrusted input and may contain prompts, source code,
terminal output, credentials and personal data. hutchbar decodes only the fields it needs
(session ids, event types, timestamps, tool-call statuses, model names, token counters,
quota readings, the working folder) and ignores prompt bodies, replies, tool input/output
and credentials. Paths are read with bounded sizes; symlinks are rejected, not followed.

| Agent | Read |
|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` (incl. subagent `*.meta.json`), `~/.claude/sessions/*.json` |
| Codex | `~/.codex/sessions/**/*.jsonl` |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.json`, `.project_root` |
| Qwen Code | `~/.qwen/usage/token-usage-*.jsonl` |
| OpenCode | `~/.local/share/opencode/opencode.db` (read-only SQLite) |
| Copilot CLI | `~/.copilot/session-state/*/events.jsonl` |
| ccr (optional gateway) | `~/.local/share/claude-code-router/ccr.db` (read-only SQLite) |
| Claude hooks | `~/.claude*/settings.json` (to show whether hooks are installed) |

It also lists running processes (name, parent, working folder) to nest agents started
from a terminal session under it and to see when a Codex CLI session ended.

## What it runs

To read limits from the source, hutchbar asks the installed agent CLIs, which then talk
to their own providers with your existing sign-in, exactly as when you run them yourself:

- `claude` (a usage request per Claude profile, `CLAUDE_CONFIG_DIR`);
- `codex app-server` (`account/rateLimits/read`);
- `agy -p /usage`;
- `gh auth token` — only when GitHub Copilot is installed and no Copilot token is found.

No prompt is sent. These processes get a minimal environment: `HOME`, `USER`, `LOGNAME`,
`TMPDIR`, `LANG` and proxy variables (plus the profile folder for `claude`/`codex`).

## Network

The app itself makes one kind of request: when GitHub Copilot is installed
(`~/.copilot` or `~/.config/github-copilot` exists), it asks
`https://api.github.com/copilot_internal/user` for the monthly premium-request quota,
with your Copilot or GitHub token. The token is held only for the request and never
logged, stored or shown. Nothing else leaves the Mac. Update checks are not implemented;
if added, they will be optional and disclose only the app version and your IP.

## What it writes

Everything stays in `~/Library/Application Support/hutchbar/`:

- `usage-cache.json` — per file: size, modification time and token counts per day, hour
  and model (no content), so spending is not recomputed from scratch;
- `events.jsonl` — Claude Code hook events (session id, event kind, time), written by
  `hutchbar --hook` when hooks are installed;
- settings in the app's `UserDefaults`.

It reads, but never writes, an optional `model-prices.json` there to override API prices.

Installing Claude hooks from the panel edits `~/.claude*/settings.json` after your
confirmation, keeping a dated backup next to it; removing them does the same.

## Notifications and the screen

Notifications and the attention pill show the agent, the project folder name, the session
title you set and the waiting time — never prompts or code. Raw log bytes live briefly in
bounded buffers and are not cryptographically erased; the OS can expose process memory in
local crash diagnostics, which hutchbar neither collects nor uploads.

## Distribution

Installing build tools, Developer ID timestamping, notarization and downloading releases
are developer/distribution operations, not app telemetry. Notarization sends the app or
DMG to Apple; source builds do not submit user logs.
