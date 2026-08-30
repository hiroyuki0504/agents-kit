# Contributing to agents-kit

Thanks for your interest in improving agents-kit. This document covers everything needed to develop and submit a change.

A note on language: the kit's CLI messages, `kit/PROTOCOL.md`, and `SPEC.md` are intentionally in Japanese — their primary readers are AI coding agents, which handle this natively. Community documents like this one are in English. Issues and pull requests are welcome in either language.

## Development setup

There is no build step and nothing to install:

```
git clone https://github.com/hiroyuki0504/agents-kit.git
cd agents-kit
```

Requirements (the same environment the kit itself targets):

- git 2.30+
- python3 3.9+ — standard library only; do not add third-party dependencies
- POSIX sh + bash — everything must run on macOS's stock **bash 3.2**
- Optional: `gh` (GitHub CLI) — only used for automatic PR creation; all tests run without it

## Running the tests

```
bash tests/smoke.sh && bash tests/breaker.sh
```

Both scripts build a disposable sandbox under `mktemp -d` with a **local bare origin** — no network access and no `gh` required. `smoke.sh` (29 checks) verifies the end-to-end flow (install → directive → start → done → merge); `breaker.sh` (14 checks) attacks failure modes (concurrent claim races, zombie claims after evict, stale-lock takeover, `master`-default repos, hostile pre-existing hooks, rebase conflicts, re-install idempotency). Each prints PASS/FAIL per check and exits 0 only when everything passes.

CI (`.github/workflows/tests.yml`) runs the same scripts on ubuntu-latest and macos-latest. More suites may land under `tests/` over time (e.g., uninstall and demo coverage) — when in doubt, run whatever the CI workflow runs.

Quick syntax checks while iterating:

```
bash -n install.sh tests/*.sh
python3 -c "import ast; ast.parse(open('kit/agents').read())"
```

## Pull requests

Before opening a PR:

- **Tests are green locally** (`bash tests/smoke.sh && bash tests/breaker.sh`), and CI must be green on the PR.
- **User-facing changes update both `README.md` (English) and `README.ja.md` (Japanese).**
- **Shell code stays bash 3.2 compatible.** No bash 4+ features: no associative arrays, no `${var,,}` / `${var^^}`, no `mapfile`. One known trap: `$var` immediately followed by a multibyte character (e.g., Japanese text) is misparsed as a longer variable name — always write `${var}` inside strings containing non-ASCII text.
- `kit/agents` stays python3 3.9-compatible and standard-library-only.
- Match the style of the file you touch — in particular, user-facing script output stays in Japanese.
- Behavior is specified in `SPEC.md`. If you change behavior, keep the spec, the protocol (`kit/PROTOCOL.md`), and the implementation in agreement.

Small, focused PRs merge faster than large ones.

## How this project is built

agents-kit is itself developed by multiple AI coding sessions working in parallel under human direction — design, implementation, tests, and pre-release audits included — and that work is coordinated with exactly the ideas this kit encodes: isolated per-task worktrees, an append-only instruction ledger where the newest instruction wins, and serialized merges with the full test suite run per merge. The kit is its own first user. Human contributors are equally welcome; expect issues and PRs to be read by both humans and AI agents.

## Reporting bugs and proposing features

Use the issue templates (bug report / feature request). For bugs, environment details and exact command output matter a lot — the template asks for them.

## License

MIT. By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
