# Release notes

## 2026-09-27

- Added `usage`, `checkpoint`, `run`, and `handoff` for CLI usage and context monitoring.
- Handoffs preserve the active claim, worktree, uncommitted changes, and local summary.
- Unavailable or unverified usage data prevents selection of a handoff target.
- Claude usage control uses an experimental API. Long-running alternating implementations across providers remain unverified.

## 2026-08-31 — v1.1.0

- Added English and Japanese documentation, contributor guidance, and issue/PR templates.
- Added the self-contained `demo.sh`, `agents doctor`, and marker-based uninstall support.

## 2026-08-31 — v1.0.0

- Initial release of Git-based claims, ordered directives, and serialized merges.
- See `SPEC.md` for the protocol, test requirements, and known limitations.
