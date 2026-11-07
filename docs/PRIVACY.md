# Privacy

This skeleton does not discover or read agent logs automatically. Its headless selftest
does not read user files. The core reader only reads a path explicitly supplied by its
caller. No user-facing monitoring settings or update check are implemented yet.

The planned adapters read local Claude Code journals in `~/.claude/projects/**/*.jsonl`
and Codex journals in `~/.codex/sessions/**/*.jsonl` (including nested date directories).
These files may contain prompts, source code, terminal output, credentials, and personal
data. Read access is limited to opted-in sources; symlink paths are rejected, not followed.
No files are changed. Future discovery must use bounded, explicit source directories.

Adapters will extract only session identifiers, agent/tool identity, lifecycle/state events,
event times/wait duration, and quota counters when present. They must validate schemas and
ignore prompt bodies, source fragments, tool input/output, and credentials. Those adapters
are not implemented, so no claim is made that current core byte framing filters JSON fields.

Raw bytes exist temporarily in the bounded framer and returned batches. We do not persist
or send raw journals, prompts, code, derived session history, or credentials. Consumers
must promptly release batches and keep content out of errors, notifications, and diagnostic
reports. Buffers are not cryptographically erased. The OS can expose process memory in
local crash diagnostics; hutchbar does not collect or upload crash reports.

There is no telemetry, analytics, advertising, remote logging, or network activity in the
current app. The only planned app network use for v0.1 is an optional, disableable update
check, which may disclose the client's IP and current app version to the update host.
It must never send journal contents. Sparkle and update checks are not implemented.
Subscription status from a future local ccr adapter and hutch IPC need separate review;
remote provider integrations require a privacy-policy update before implementation.

Installing dependencies/build tools, Developer ID timestamping, notarytool submissions,
and downloading releases are developer/distribution operations, not app telemetry.
Notarization sends the app or DMG to Apple; source builds do not submit user logs.
