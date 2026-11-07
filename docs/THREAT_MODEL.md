# Threat model

## Assets, boundaries, and assumptions

Assets: private agent journals/prompts/code, accurate attention state, user intent, and
release integrity. The local user chooses the sources. Journal contents, paths, event
claims, repository changes, and future IPC requests are untrusted. The core reader is a
byte framer, not an authenticator or JSON-schema validator. UI and log adapters are separate
trust boundaries. The repository/CI boundary separates untrusted PR code from release secrets.

A compromised OS/root account and a malicious process with the same uid are outside the
v0.x trust guarantee. File permissions and getpeereid identify a uid, not an application.
Ad-hoc signing cannot authenticate the publisher. Developer ID plus a reviewed protocol
is needed before any reliable client-identity claim; a signature alone does not authorize
an operation. No action approval is implemented in this skeleton.

## Threats and defenses

| Threat | Current defense / remaining work |
| --- | --- |
| Prompts/code leaked from logs into diagnostics | Fixed content-free errors and count-only descriptions; no logging or uploads. Explicit raw bytes remain sensitive in memory. Future adapters must extract minimal fields. |
| Huge or incomplete JSONL, flooding/DoS | 1 MiB line limit, discard counter, 64 KiB read budget, partial-line handling. Consumers must bound retained batches, history, scheduling, and queues. |
| Log rotation, truncation, misleading state | Descriptor device/inode/size checks reset partial state. Truncate-and-regrow or same-inode rewrites between polls can evade detection; events must not confer authority. |
| Symlink substitution/check-open races | Directory-descriptor openat traversal with O_NOFOLLOW on every component; only regular files. Hard links/same-user modification remain possible. |
| Forged approval by a local process | No approval/control endpoint exists. Future socket mode 0600, uid check, session-bound one-time tokens tied to exact operation, atomic consume, deny by default. Same-uid impersonation remains an explicit v0.x limit. |
| Malicious CI/PR or dependency | SHA-pinned actions, permissions {}, no PR secrets, no pull_request_target, credential-free checkout, workflow linting, gitleaks history scan, weekly Dependabot. Brew tools and downloaded checksums still trust their distribution hosts. |
| Forged/mutable release | Owner-only tag preflight, verified commit on main, matching version/changelog, protected signing environment, separate publish token, checksums and downloaded-asset comparison, immutable-release check. Attestations only when public. |
| Replaced update | No updater yet. Next step is Sparkle 2 with EdDSA and HTTPS, optional checks. HTTPS/checksums alone are not publisher authentication. |
| User over-trusts UI | Document pre-alpha scope; session status is advisory and cannot prove safety. No sandboxing of agents occurs in hutchbar. |

## Separate hutch integration (future, not implemented here)

A permitted API is still an exfiltration channel for any data available to an agent. A
sandbox can protect the Mac without protecting project data from an allowed provider;
use no external network for confidential projects. Future integration must retain this warning.

Hutch must separately review VM isolation/resource quotas; project-copy exclusions for
`.git`, `.env*`, keys, sockets and nested filesystems; safe apply with full diff and
metadata; no-follow descriptor-relative writes; and executable/hook/CI changes highlighted.
A guest should have no NAT, with DNS only via policy proxy, IP literals denied by policy,
no private/link-local/metadata access, validated DNS pinned to each connection, and matching
CONNECT authority/SNI/Host. Bound VM CPU/RAM/disk and log/copy sizes, fail closed if the
proxy dies, and verify signed guest-image bytes before running them without a replacement race.

Key substitution needs an operation-level API proxy (method/host/port/path allowlist,
one specific Authorization header, no redirects or cross-origin connection reuse).
V0.1 hutch's explicit limited key is visible in the guest; do not claim invisible credentials.
These are hutch requirements and review topics, not implemented hutchbar defenses.

## Validation gaps

Synthetic tests cover the reader and actual local filesystem safeguards; sanitizers and
leaks supplement behavior tests. Interactive AppKit lifetime, sustained resource budgets,
real journal schemas, TCC, actual signed/notarized downloads, and future IPC require manual
review/testing. No security claim should be inferred from source/configuration alone.
