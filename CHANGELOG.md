# Changelog

All notable changes are documented here, following [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Menu bar item: the monochrome hutch logo and the number of sessions waiting for you
  (an orange pill when one needs an approval).
- Panel: «Ждут тебя» / «Работают» cards with nested calls as a tree (Claude subagents,
  Codex child threads, agents started from a terminal session), quiet sessions folded away,
  click to jump to the agent's window (Warp, iTerm2, Terminal, Ghostty, IDEs, desktop apps).
- Attention pill at the top of the screen when an agent waits longer than a threshold.
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
- Swift Testing, sanitizers, leak smoke test, linting, hooks, and protected release tooling.

No release has been published. The source version is 0.0.1; create a dated release entry
before tagging a release.
