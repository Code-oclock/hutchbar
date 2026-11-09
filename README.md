# hutchbar

A macOS menu bar cockpit for coding agents: who is waiting for you and why, who is working
(and whom they called), how much of every subscription is left, and what the day cost at
API prices. **Pre-alpha (0.0.1)**; private until v0.1. Requires macOS 14 or later.
Maintained by [Code-oclock](https://github.com/Code-oclock). Licensed under
GPL-3.0-or-later; see [LICENSE](LICENSE).

## What it shows

- **Menu bar:** the hutch logo and the number of sessions waiting for you; the number sits
  in an orange pill when an agent asks for an approval.
- **Waiting for you / Working:** live sessions with the reason («разрешение», «твой ход»),
  waiting time and a click-through to the agent's window (Warp, iTerm2, Terminal, Ghostty,
  IDEs, desktop apps). Nested calls appear under their parent while they run: Claude
  subagents, Codex child threads, OpenCode subagents, and agents started from a terminal
  session (for example Codex or Antigravity called by Claude Code). Sessions silent longer
  than a threshold fold into one line.
- **Limits:** read from the source, every account separately, with countdowns and an
  even-pace marker: Claude (`claude` usage per profile), Codex (`codex app-server`),
  Antigravity (`agy /usage`), GitHub Copilot (premium requests per month). Accounts seen
  only through a gateway (ccr) sit in a separate collapsed list, since a gateway cannot
  tell which subscription each alias is.
- **Spending:** tokens and cost at API prices per agent and model, by hour or day.
- **Attention pill** at the top of the screen when an agent waits longer than a threshold.

Agents: Claude Code, Codex (CLI, desktop, IDE), Antigravity, Gemini CLI, Qwen Code,
OpenCode, GitHub Copilot CLI. Not every agent exposes every kind of data; hutchbar shows
what each one records locally. Russian and English, following the system language.

hutchbar works on its own; the separate **hutch** agent sandbox will later add a view of
the network requests its agents make.

## Claude Code hooks

Without hooks, hutchbar infers Claude Code's state from its transcripts. With hooks it
knows exactly when Claude asks for an approval or finishes a turn. The panel footer shows
whether they are installed and offers the snippet for `~/.claude/settings.json`; the
hooks only run `hutchbar --hook`, which appends a content-free event to
`~/Library/Application Support/hutchbar/events.jsonl`.

## Privacy

Everything stays on your Mac: no telemetry, no analytics, no remote logging. hutchbar reads
agent logs and databases (decoding only ids, states, times, model names and counters),
asks installed agent CLIs for their limits, and makes one network request of its own — the
Copilot quota, only when Copilot is installed. Details: [privacy](docs/PRIVACY.md).

## Build from source

Install Swift 6.4 Command Line Tools on macOS; a full Xcode installation is optional.
There are no external Swift package dependencies and no Xcode project.

```sh
./build.sh --release --selftest
open build/Hutchbar.app
./build.sh --dev                  # build/Hutchbar Dev.app; separate .dev bundle ID
./build.sh --test                 # Swift Testing, no XCTest
./build.sh --asan                 # Address Sanitizer
./build.sh --tsan                 # Thread Sanitizer (use Xcode on CI)
./build.sh --leaks                # release app selftest under leaks --atExit
./build.sh --dmg                  # dist/Hutchbar-0.0.1.dmg
build/Hutchbar.app/Contents/MacOS/hutchbar --version
```

`build.sh` uses SwiftPM and codesign, never xcodebuild. CLT-only Swift 6.4 needs the
native SwiftPM backend and explicit Testing framework/plugin paths for tests; the script
selects these only for CLT. The native backend is deprecated upstream. CI uses the normal
backend with Xcode on `macos-26`. Some CLT environments cannot launch TSan; CI with Xcode is the reference check.
Sanitizer builds have separate scratch directories and are never packaged. The leak smoke
test temporarily enables debugger access for leaks, then restores the production signature;
see the ownership/validation notes in [architecture](docs/ARCHITECTURE.md).

With no `HUTCHBAR_SIGN_IDENTITY`, builds are ad-hoc signed with hardened runtime.
To keep a stable local signing identity across rebuilds, explicitly run
`Tools/setup-signing.sh` and use the export it prints. This changes your login keychain;
builds themselves do not. It may help preserve TCC grants; it does not grant permissions
or replace Developer ID/notarization. See [releasing](docs/RELEASING.md).

## Security model and limitations

Agent logs are untrusted and may contain prompts, source code, and secrets. The reader
bounds line and read sizes, retains incomplete lines, detects inode/device changes and
observed truncation, rejects symlinks in every path component, and emits content-free
errors and descriptions. Parsers decode only the fields they need and never put log
content into errors, notifications or descriptions.

There is no App Sandbox entitlement. Hardened runtime is enabled, but ad-hoc signing
cannot authenticate a publisher. A same-user malicious process can replace logs or
impersonate an agent; v0.x does not solve that trust problem. hutchbar never approves
anything on an agent's behalf. Monitoring is not evidence that an agent or its actions are safe.

Hutchbar does not restrict an agent's filesystem or network. Even a future hutch integration
cannot prevent exfiltration through a permitted external API; use an offline workflow for
confidential projects. See [threat model](docs/THREAT_MODEL.md) and [privacy](docs/PRIVACY.md).
There is no telemetry, automatic updater, or persistent session database. Future update
checks must be optional.

## Contribute and verify

Read [CONTRIBUTING.md](CONTRIBUTING.md). Work in branches and merge through PRs.
`Tools/install-hooks.sh` opts into local hooks. `Tools/apply-rulesets.sh` previews
GitHub protections; `--apply` changes them. Private repositories on unsupported GitHub
plans rely on local hooks until protections are available. No setup script is run automatically.

CI installs SwiftLint and swift-format with Homebrew and treats them as required checks,
with a 15-minute job timeout. A missing tool fails CI instead of silently weakening checks.
Local pre-commit hooks warn and skip unavailable tools. Linux jobs run workflow and
secret checks; expensive macOS jobs run for PRs/main and ignore documentation-only changes.
Use workflow_dispatch to check main after a documentation-only change if needed.
CodeQL and provenance attestations run only after the repository becomes public.

## Roadmap

- v0.1: done — sessions, nested calls, limits, spending, attention pill, terminal
  navigation, seven agents. Remaining: one-click Claude hooks, system notifications,
  first signed release.
- Next: Sparkle 2 updates with EdDSA signatures and a Code-oclock Homebrew tap.
  Neither is implemented here.
- v0.2: hutch network approval UI only after the client-identity/trust design is reviewed.
