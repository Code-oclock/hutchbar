# Changelog

All notable changes are documented here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Homebrew tap `code-oclock/hutchbar` (cask updated by the release workflow).
- Self-signed release builds: with a stable release certificate, updates keep macOS
  notification and Automation permissions. Release notes carry the certificate fingerprint.

## [0.1.0] - 2026-11-09

### Added

- Menu bar item: the monochrome hutch logo and the number of sessions waiting for you
  (an orange pill when one needs an approval).
- Panel: «Ждут тебя» / «Работают» cards with nested calls as a tree (Claude subagents,
  Codex child threads, agents started from a terminal session), quiet sessions folded away,
  click to jump to the agent's window (Warp, iTerm2, Terminal, Ghostty, IDEs, desktop apps).
- Attention pill at the top of the screen and a system notification when an agent waits
  longer than a threshold (one per wait, withdrawn when it ends, click to jump).
- One-click Claude Code hooks: install with a confirmation and a dated backup of
  `settings.json`, stale-path detection, removal from the menu.
- Agents: Claude Code, Codex (CLI, desktop, IDE), Antigravity, Gemini CLI, Qwen Code,
  OpenCode, GitHub Copilot CLI.
- Limits read from the source: `claude` usage per profile, `codex app-server`,
  `agy /usage`, Copilot premium requests; every account in its own card with countdowns
  and an even-pace marker; gateway (ccr) accounts in a separate collapsed list.
- Spending at API prices per agent and model, with a trend by hour or day; the price list
  comes from Vorssaint (GPL-3.0) via `Tools/gen-model-prices.py`.
- Russian and English UI following the system language.
- `--render-panel`, `--render-icon`, `--probe-limits` for checks without starting the app.
- Incremental, size-bounded JSONL tail reader with symlink rejection and rotation handling.
- Verification status: Claude Code, Codex and Antigravity were checked on a live Mac.
  Gemini CLI, OpenCode, Copilot CLI and Qwen Code are covered by synthetic tests only
  (no live installation); formats may differ in the wild — please report.
- Swift Testing, sanitizers, leak smoke test, linting, hooks, and protected release tooling.
