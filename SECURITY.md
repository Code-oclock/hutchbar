# Security policy

Only the latest released version is supported. Before the first release, fixes target
main; this pre-alpha is not suitable for security-sensitive approval workflows.

Report vulnerabilities **only** through
[GitHub Private Vulnerability Reporting](https://github.com/Code-oclock/hutchbar/security/advisories/new).
Do not open public issues or paste real logs, prompts, source code, keys, or tokens.
The maintainer must enable private vulnerability reporting when the repository becomes public.
If the private reporting form is unavailable before that transition, wait until the
repository's private security channel is available; no public fallback is authorized.

This is a best-effort volunteer project. We aim to acknowledge reports within seven days
and provide an initial assessment within thirty days, without a response-time guarantee.
Coordinate disclosure through the private advisory.

In scope: log parsing and file handling, unintended disclosure, resource exhaustion,
release/update integrity, future approval-channel authentication, and unsafe trust boundaries.
Out of scope: malicious processes already running as the same user (v0.x limitation),
compromised OS/root accounts, agent/provider vulnerabilities outside hutchbar, and claims
that monitoring alone should sandbox an agent or stop exfiltration through an allowed API.
See [THREAT_MODEL.md](docs/THREAT_MODEL.md); reproducible failures of documented defenses
remain in scope even when the input is attacker-controlled.
