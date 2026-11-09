# Releasing

## One-time repository setup

Keep the repository private until v0.1. Install local hooks. Preview
`Tools/apply-rulesets.sh`, then run it with `--apply` only as an administrator when ready.
It upserts named rulesets and the `release` environment; it does not replace unrelated
rulesets. Its required checks are listed in REQUIRED_CHECKS at the top of the script.
Main requires a PR, zero approvals (single maintainer), stale-review dismissal, resolved
threads, checks, linear history and verified signatures; admin bypass is PR-only.
Version tags cannot be deleted, updated or force-pushed, including by an admin; a separate
creation rule permits repository admins to create them. No secret-bearing step runs on PRs.

The environment accepts only `v*` tags and requests owner review (self-review allowed for
a solo maintainer). GitHub private-plan limitations may reject rulesets or environment
reviewers: the script fails with an explanation; keep local pre-push protection until
support is available. Configure supported settings manually if a partial apply succeeded.
Enable immutable releases in repository settings; enable Private Vulnerability Reporting
and secret scanning/push protection when public. Review settings before the first release.

GitHub required checks plus workflow-level paths-ignore can leave documentation-only
PRs pending. A dispatch on main cannot satisfy the PR head. After reviewing an exclusively
documentation diff and running relevant local checks, the repository admin can use the
configured **PR-only** bypass to merge that PR. Do not weaken required checks globally or
push directly to main. Code changes must pass CI. An always-reporting path gate is a
possible future improvement if the docs-only bypass becomes inconvenient.

## Optional Developer ID credentials

With **all** these environment secrets, the build imports Developer ID into a temporary
runner keychain, uses secure timestamps, notarizes/staples the app before ZIP/DMG packaging,
then signs and notarizes/staples the DMG:

- SIGNING_CERT_P12: base64 PKCS#12 containing certificate and private key.
- SIGNING_CERT_PASSWORD: PKCS#12 password.
- SIGNING_IDENTITY: full `Developer ID Application: ...` identity name.
- NOTARY_API_KEY_P8: raw App Store Connect API private-key PEM.
- NOTARY_KEY_ID and NOTARY_ISSUER_ID: API key identifiers.

Only the environment-protected build job receives these secrets. Incomplete/absent
credentials produce an ad-hoc build with an automatic **Unsigned build** release-notes
block; failed signing or notarization with complete credentials fails the release.
No credentials, keychains, or temporary P8/P12 files are uploaded. Signing keychain cleanup
runs even after failure. Never put credentials in a repository or issue.

For local stable identity only, explicitly run `Tools/setup-signing.sh`, accept the login
keychain trust prompt if macOS asks, and use the printed HUTCHBAR_SIGN_IDENTITY export.
This self-signed code-signing certificate is not Developer ID/notarization and only aims
to preserve TCC identity across rebuilds. Keep it local. `Tools/notarize.sh` prints
“skipped” and exits 0 if the NOTARY variables are missing; CI enables it only with complete credentials.

## Optional Homebrew tap update

[`Code-oclock/homebrew-hutchbar`](https://github.com/Code-oclock/homebrew-hutchbar) holds the
cask. With the `TAP_TOKEN` environment secret (a fine-grained personal access token limited to
that one repository, **Contents: read and write**, short expiry), the `tap` job runs after a
stable release is published and commits the new `version` and `sha256` through
`Tools/update-cask.py`. Prereleases are skipped. Without the secret the job only prints a
notice; update the cask by hand. The job needs a second approval of the `release`
environment. The token is never available to build or publish jobs.

## Prepare and tag

1. Run all CI checks and manually inspect menu bar/About/Quit on a real Mac. Measure idle
   CPU/RSS against architecture goals; record results. Run TSan with Xcode and test downloads
   if signing/notarization configuration changed.
2. In a branch, update `HutchbarVersion.current` in SessionState.swift and
   CFBundleShortVersionString in Resources/Info.plist to the exact SemVer (including prerelease
   suffix if applicable). Increment CFBundleVersion. Move Unreleased changes under
   `## [X.Y.Z] - YYYY-MM-DD`; leave an Unreleased section. Get the PR reviewed and merged.
3. Fetch main, verify the intended commit, then create a signed annotated tag as Code-oclock:
   `git tag -s vX.Y.Z -m 'Release vX.Y.Z' <verified-main-sha>` and push only that tag.
   Accepted tags: `vX.Y.Z`, `vX.Y.Z-alpha.N`, `vX.Y.Z-beta.N`, `vX.Y.Z-rc.N`.
   This is a manual maintainer step; scripts never tag or push.
4. Approve the `release` environment deployment after reviewing the preflight source.

Preflight requires both actor and triggering_actor Code-oclock, canonical SemVer, a GitHub
verified tag-target commit, ancestry on main, matching source/plist/tag, dated nonempty
changelog, and Swift tests. It validates the commit signature, not just the annotated tag.
The build rechecks the source and uses the preflight SHA, runs the headless selftest, packages
`Hutchbar-X.Y.Z.zip` with ditto and `Hutchbar-X.Y.Z.dmg` using hdiutil UDZO, generates a syft
SPDX JSON SBOM, release-notes.md, and SHA256SUMS, then uploads one short-lived artifact.
The release uses the runner's native arm64 architecture; it is not a universal/Intel build.

A separate public-only provenance job gets OIDC/attestation permissions. The publish job
has contents:write and no Apple secrets or OIDC. It checks sums, revalidates tag/main,
creates a draft, downloads and byte-compares every asset and notes, publishes, and repeats
asset verification. Existing releases are refused rather than overwritten; investigate
and explicitly remove a failed draft before retrying. Published tags are never rewritten.
Private mutable releases warn; a public mutable release fails the final check. Enable
immutable releases before publishing publicly. There is no cosign/Rekor step for hutchbar.

## Verify the download

Download ZIP or DMG, the SBOM, release-notes.md, and SHA256SUMS from the same release:

```sh
shasum -a 256 -c SHA256SUMS
codesign --verify --strict /Applications/Hutchbar.app
/Applications/Hutchbar.app/Contents/MacOS/hutchbar --version
/Applications/Hutchbar.app/Contents/MacOS/hutchbar --selftest
# Only for Developer ID/notarized artifacts:
xcrun stapler validate /Applications/Hutchbar.app
spctl --assess --type execute --verbose /Applications/Hutchbar.app
# Only after this repository is public:
gh attestation verify Hutchbar-X.Y.Z.zip --repo Code-oclock/hutchbar
```

Checksums detect corruption, not a malicious publisher. For an ad-hoc download that you
have verified and chosen to trust, the release notes include:
`xattr -dr com.apple.quarantine /Applications/Hutchbar.app`.
It removes quarantine; it does not authenticate the app or turn it into a notarized build.
Sparkle and Homebrew distribution are future work only.
