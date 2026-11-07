# Contributing

Use a feature/fix branch and a pull request into `main`. Keep history linear (squash merge),
keep main buildable, and sign every commit with an SSH or GPG key verified by GitHub.
Use a GitHub noreply address if you do not want your email published. PR titles and commits
follow Conventional Commits: `type(scope): imperative`, for example
`fix(core): discard a partial line after rotation`. Small scopes can be omitted.

## Local checks

Swift 6.4 and macOS 14+ are required. Install optional development tools yourself:
`brew install swiftlint swift-format gitleaks actionlint zizmor`.

```sh
Tools/install-hooks.sh
./build.sh --test
./build.sh --release --selftest
./build.sh --asan
./build.sh --leaks
swiftlint lint --strict
swift-format lint --strict --recursive Package.swift Sources Tests
# CLT also includes: swift format lint --strict --recursive Package.swift Sources Tests
```

TSan runs with `./build.sh --tsan` on CI's Xcode toolchain; some local CLT environments
cannot launch it. Do not disable the CI check if your local runtime fails. Use Swift Testing (`import Testing`), never a custom test runner or XCTest dependency.
Put deterministic behavior tests in HutchbarCoreTests; fake system boundaries. Add
lifecycle/weak-reference tests whenever ownership or background work changes.

Pre-commit scans staged changes with gitleaks and lints staged Swift bytes. It never
rewrites files. Missing tools produce a yellow warning and are skipped locally; CI is
mandatory. Pre-push blocks every update to `refs/heads/main`, including deletion, then
runs quick tests for other pushes. `HUTCH_ALLOW_MAIN_PUSH=1 git push ...` is a one-time
bootstrap escape hatch, not a normal workflow. Do not use it to bypass review.
Installing hooks sets repository-local `core.hooksPath`; worktrees can share this setting.

Protect raw logs: use synthetic fixtures, never attach real prompts, credentials, or
private code. Follow [architecture](docs/ARCHITECTURE.md) memory/cancellation rules.
Update the changelog for user-visible changes. Report vulnerabilities only through
[GitHub Private Vulnerability Reporting](https://github.com/Code-oclock/hutchbar/security/advisories/new).

## CI and repository settings

CI includes workflow-lint, secrets, build-test, both sanitizers, leaks, and lint. The
rulesets script lists these exact required job names at its top. Documentation-only
changes intentionally skip CI, so GitHub's required checks may stay pending. An explicit
CI dispatch on main does not satisfy a PR head. For a documentation-only PR, the repository
admin may use the configured PR-only bypass after reviewing the diff and running relevant
local checks; never push directly to main or weaken required checks globally. Code-bearing
PRs must pass CI. A manual dispatch on a PR branch runs only Linux jobs.

Dependabot groups weekly GitHub Actions and Swift updates (there are no Swift dependencies
yet). Tools installed with brew are unpinned development tools; action SHAs are pinned.
Actionlint and gitleaks have explicit versions/checksums in CI. Review tool upgrades as
supply-chain changes. CodeQL is public-only, because private scanning requires a paid plan.
