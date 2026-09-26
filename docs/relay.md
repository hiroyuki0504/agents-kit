# Capacity-aware AI handoff

`agents run` is an opt-in foreground supervisor for an existing claim worktree. It creates a fresh provider session and switches providers when subscription quota or context reaches a configured threshold. `agents handoff` lets an existing, cooperating AI call that supervisor for a successor. It does not attach to or kill an existing interactive application.

## Configuration

Add `relay` to the existing clone-local `.agents/config.json`; retain `test_cmd`, `main_branch`, and other existing keys. Rerun the installer to update existing installations. Defaults work with installed, logged-in `codex` and `claude` CLIs.

```json
{
  "quota_threshold": 15,
  "context_threshold": 15,
  "min_remaining": 25,
  "max_handoffs": 3,
  "max_age_seconds": 300,
  "poll_seconds": 30,
  "probe_timeout_seconds": 20,
  "stop_timeout_seconds": 10,
  "providers": {
    "codex": {
      "kind": "codex",
      "command": ["codex", "exec", "--json", "-"]
    },
    "claude": {
      "kind": "claude",
      "command": ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
    }
  }
}
```

This JSON is the **value of `relay`**, not a replacement for the config file. Supplying `providers` replaces the default provider list. Set `enabled: false` to exclude an entry. Commands are argument arrays executed directly, never shell strings. Custom CLI flags retain their normal meaning; no approval/sandbox bypass is added. Permission requests that require an interactive host are denied and reported, so configure the CLI's normal project permissions before unattended use.

| Setting | Meaning |
|---|---|
| `quota_threshold` | Switch when any fresh included usage window has this percentage or less remaining |
| `context_threshold` | Switch when the current session has this percentage or less remaining |
| `min_remaining` | Candidate must have **more** than this percentage left in every observed quota window; must exceed `quota_threshold` |
| `max_handoffs` | Maximum automatic transitions in a run; providers already used in that run are excluded |
| `max_age_seconds` | Reject observations older than this; future timestamps and elapsed reset windows are also rejected |
| `poll_seconds` | Usage refresh and claim heartbeat interval; Claude context is checked at most every 5 seconds |
| `probe_timeout_seconds` | Deadline for provider usage queries and Claude initialization |
| `stop_timeout_seconds` | Grace period for SIGINT, followed by bounded SIGTERM/SIGKILL cleanup of the worker group |

An explicit initial `--provider` may run with unknown quota. Automatic selection and every successor require verified quota. Context measurements belong to one conversation and are discarded on switching; available quota belongs to the provider/account. An expired quota observation does not imply that a reset refilled the account.

## Telemetry and compatibility

- **Codex**: the app-server `initialize` → `initialized` → `account/rateLimits/read` exchange uses CLI authentication and sends no inference request. Selection uses the `codex` entry in `rateLimitsByLimitId`, with the legacy single bucket as a fallback. Set `limit_id` for a different explicitly identified bucket. Worker `thread.started` identifies the exact rollout; only that file's `token_count.info.last_token_usage` and `model_context_window` supply context usage. Lifetime token totals are not context size. Ephemeral sessions without telemetry leave context unknown.
- **Claude**: stream JSON control requests `initialize` → `get_usage` (`skip_behaviors: true`) retrieve plan windows without inference or scanning other conversations. The running worker also answers `get_context_usage` with `detail: "summary"`; `totalTokens / maxTokens` measures current context. Usage control is experimental: a timeout, unsupported method, missing subscription fields, or invalid schema yields unknown capacity. Stream rate-limit events supplement these observations. Extra paid usage is not considered spare included capacity. An optional `context_window_tokens` supplies a known, explicitly configured capacity for versions that only expose per-message usage; input and cache tokens count toward context, cumulative totals and subagent messages do not.
- **Other AIs**: use `kind: "custom"`, `command`, and `usage_command` as below. Separate entries can use different wrappers, but quota probes must measure the same account/model as the worker command. For Codex profiles or wrappers that change authentication, supply a matching `usage_command`; the default Codex probe uses the executable's default app-server account.

Read-only native usage probes were checked against Codex CLI 0.157.1 and Claude Code 2.1.283. The protocol fixtures in the test suite are offline; supported APIs can change independently of agents-kit.

Primary references: [Codex app-server](https://learn.chatgpt.com/docs/app-server), [Claude Agent SDK types](https://platform.claude.com/docs/en/agent-sdk/typescript), [Claude status line usage fields](https://code.claude.com/docs/en/statusline). The experimental Claude control shapes were also checked against Anthropic's published `@anthropic-ai/claude-agent-sdk` 0.3.283 types and transport.

## Custom adapter contract

`usage_command` runs in the claim worktree, receives no input, exits 0, and prints **one JSON line**. It can be used with any provider kind. All observations require their actual Unix timestamp or timezone-qualified ISO timestamp; never relabel an old cached observation as newly fetched.

```json
{"windows":{"five_hour":{"remaining_percent":80,"observed_at":1790450000,"resets_at":1790460000},"seven_day":{"remaining_percent":60,"observed_at":1790450000,"resets_at":1790900000}}}
```

`resets_at` is optional. Include every applicable limiting window; a missing percentage is unknown, not zero usage. These example timestamps must be replaced with real observations.

The custom worker receives the task/handoff prompt on stdin (EOF-terminated). It prints JSONL events. Emit telemetry whenever it changes:

```json
{"type":"agents_usage","windows":{"five_hour":{"remaining_percent":12,"observed_at":1790450030}},"context":{"remaining_percent":40,"observed_at":1790450030}}
```

Finish with `{"type":"agents_result","success":true}` and exit 0. Any nonzero exit, failure result, or missing terminal result is a failure; the supervisor will not reinterpret arbitrary error text as capacity exhaustion. The worker must stay in its process group and cooperate with SIGINT. Spawned tool processes are stopped before a successor starts.

## Persistence and recovery

`agents checkpoint --text ...` or `--file ...` saves a small progress summary. `run`/`handoff` save `handoff.json`, `prompt.txt`, `run.json`, and normalized usage plus bounded stderr logs in `<worktree-git-dir>/agents-relay/`. Files are created with owner-only permissions. No shared quota record, credentials, or conversation archive is pushed to `agent-state`. The existing claim continues to reserve the same paths; every launch verifies its owner, branch, and Git operation state. Stop at an unresolved rebase, merge, cherry-pick, or Git lock rather than launching over it.

Exit 9 means capacity-related pause, transition limit, or return from an explicit handoff. Read the message and `run.json` to distinguish them. Exit 6 means execution/permission/probe failure, not completion. `returned` means that the worker produced a successful terminal result, **not** that tests passed or main was updated. The existing `agents done` and `agents merge` remain the verification gates.

After an interrupted run, inspect saved work and resolve any interrupted Git operation. A new explicit invocation can resume from the same files and summary. Local advisory locks release when the supervisor exits; there is no stale lock-file deletion procedure. SIGKILL of the supervisor or tool processes deliberately detached into separate sessions cannot be cleaned up by a Python signal handler: verify those processes have stopped before restarting. The relay never automatically evicts a claim, discards modifications, or purchases more quota.
