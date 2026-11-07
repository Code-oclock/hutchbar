# hutchbar

A macOS menu bar cockpit for coding agents. **Pre-alpha (0.0.1)**; private until v0.1.
Requires macOS 14 or later. Maintained by [Code-oclock](https://github.com/Code-oclock).
Licensed under GPL-3.0-or-later; see [LICENSE](LICENSE).

The intended product brings together Claude Code and Codex session states, waiting-time
notifications, subscription limits, and shortcuts to the right terminal tab. It will work
independently and later integrate with the separate **hutch** agent sandbox.

This skeleton provides an SF Symbol menu bar icon, About/Quit, a tested incremental
JSONL reader, and repository/release tooling. It does **not** discover agent sessions,
interpret agent event schemas, display live agents, request approvals, or sandbox agents.

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
errors and descriptions. Callers explicitly receive raw bytes and must keep them out of
diagnostics. JSON schema validation belongs in future adapters.

There is no App Sandbox entitlement. Hardened runtime is enabled, but ad-hoc signing
cannot authenticate a publisher. A same-user malicious process can replace logs or
impersonate an agent; v0.x does not solve that trust problem. No approval channel exists
yet. Monitoring is not evidence that an agent or its actions are safe.

Hutchbar does not restrict an agent's filesystem or network. Even a future hutch integration
cannot prevent exfiltration through a permitted external API; use an offline workflow for
confidential projects. See [threat model](docs/THREAT_MODEL.md) and [privacy](docs/PRIVACY.md).
There is no network activity, telemetry, automatic updater, or persistent session database
in this skeleton. Future update checks must be optional.

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

- v0.1: Claude Code/Codex adapters, session list, waiting notifications, subscription
  limits, terminal navigation, diagnostics without log contents, optional update checks.
- Next: Sparkle 2 updates with EdDSA signatures and a Code-oclock Homebrew tap.
  Neither is implemented here.
- v0.2: hutch network approval UI only after the client-identity/trust design is reviewed.
