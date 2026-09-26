"""Opt-in, sequential AI handoff. Python 3.9+, standard library only.

Provider processes keep their own authentication and permission settings. Only
normalized usage and a small local checkpoint cross the provider boundary.
"""

import fcntl
import json
import math
import os
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path


DEFAULTS = {
    "quota_threshold": 15,
    "context_threshold": 15,
    "min_remaining": 25,
    "max_handoffs": 3,
    "max_age_seconds": 300,
    "poll_seconds": 30,
    "probe_timeout_seconds": 20,
    "stop_timeout_seconds": 10,
}
PRESETS = {
    "codex": {"kind": "codex", "command": ["codex", "exec", "--json", "-"]},
    "claude": {"kind": "claude", "command": [
        "claude", "-p", "--input-format", "stream-json",
        "--output-format", "stream-json", "--verbose"]},
}
NAME = re.compile(r"^[a-z][a-z0-9_-]{0,39}$")
CAP = 2 * 1024 * 1024


class RelayError(Exception):
    def __init__(self, message, code=3):
        super().__init__(message)
        self.code = code


def number(value):
    return (isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value))


def epoch(value):
    if number(value):
        return float(value)
    if isinstance(value, str):
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
            return dt.timestamp() if dt.tzinfo is not None else None
        except ValueError:
            pass
    return None


def observation(remaining, observed=None, resets=None):
    if not number(remaining) or not 0 <= remaining <= 100:
        return None
    result = {"remaining_percent": float(remaining),
              "observed_at": time.time() if observed is None else epoch(observed)}
    if resets is not None:
        result["resets_at"] = epoch(resets)
        if result["resets_at"] is None:
            return None
    return result if result["observed_at"] is not None else None


def used_observation(used, observed=None, resets=None, scale=1):
    if not number(used) or used < 0:
        return None
    return observation(max(0, 100 - used * scale), observed, resets)


def fresh(obs, cfg, now=None):
    now = time.time() if now is None else now
    if not isinstance(obs, dict):
        return False
    value, stamp = obs.get("remaining_percent"), epoch(obs.get("observed_at"))
    reset = epoch(obs.get("resets_at"))
    return (number(value) and 0 <= value <= 100 and stamp is not None
            and -5 <= now - stamp <= cfg["max_age_seconds"]
            and ("resets_at" not in obs or (reset is not None and reset > now)))


def quota(snapshot, cfg):
    windows = snapshot.get("windows", {})
    # Never turn a stale/exhausted window into a fresh 100% window at reset.
    if not windows or not all(fresh(w, cfg) for w in windows.values()):
        return None
    return min(w["remaining_percent"] for w in windows.values())


def low_reason(snapshot, cfg):
    # One low window suffices, even when another window is unknown/stale.
    if any(fresh(w, cfg) and w["remaining_percent"] <= cfg["quota_threshold"]
           for w in snapshot.get("windows", {}).values()):
        return "quota"
    context = snapshot.get("context")
    if fresh(context, cfg) and context["remaining_percent"] <= cfg["context_threshold"]:
        return "context"
    return None


def normalized(raw):
    """The custom adapter wire format. Preserve observation timestamps."""
    if not isinstance(raw, dict) or not isinstance(raw.get("windows", {}), dict):
        raise RelayError("usage JSON は windows オブジェクトが必要")
    out = {"windows": {}}
    for name, item in raw.get("windows", {}).items():
        if not isinstance(item, dict):
            raise RelayError("usage window が不正: " + str(name))
        obs = observation(item.get("remaining_percent"), item.get("observed_at", 0),
                          item.get("resets_at"))
        if obs is None:
            raise RelayError("usage window の数値/時刻が不正: " + str(name))
        out["windows"][name] = obs
    if raw.get("context") is not None:
        c = raw["context"]
        if not isinstance(c, dict):
            raise RelayError("context が不正")
        out["context"] = observation(c.get("remaining_percent"), c.get("observed_at", 0))
        if out["context"] is None:
            raise RelayError("context の数値/時刻が不正")
    return out


def codex_usage(raw, limit_id="codex", observed=None):
    out = {"windows": {}}
    if not isinstance(raw, dict):
        return out
    buckets = raw.get("rateLimitsByLimitId")
    if isinstance(buckets, dict):
        bucket = buckets.get(limit_id) or {}
    else:
        bucket = raw.get("rateLimits") or raw.get("rate_limits") or {}
        if not isinstance(bucket, dict) or bucket.get("limitId", bucket.get("limit_id", "codex")) != limit_id:
            return out
    if not isinstance(bucket, dict):
        return out
    for key in ("primary", "secondary"):
        w = bucket.get(key)
        if isinstance(w, dict):
            obs = used_observation(w.get("usedPercent", w.get("used_percent")), observed,
                                   w.get("resetsAt", w.get("resets_at")))
            out["windows"][key] = obs
    return out


def claude_usage(raw, statusline=False, observed=None):
    out = {"windows": {}}
    if not isinstance(raw, dict):
        return out
    limits = raw.get("rate_limits") or {}
    if not isinstance(limits, dict):
        return out
    for key, w in limits.items():
        if key == "extra_usage" or not isinstance(w, dict):
            continue
        obs = used_observation(w.get("used_percentage" if statusline else "utilization"),
                               observed, w.get("resets_at"))
        out["windows"][key] = obs
    context = raw.get("context_window") or {}
    obs = observation(context.get("remaining_percentage"), observed) if isinstance(context, dict) else None
    if obs:
        out["context"] = obs
    return out


def settings(raw):
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise RelayError("config の relay はオブジェクトで指定せよ")
    unknown = set(raw) - set(DEFAULTS) - {"providers"}
    if unknown:
        raise RelayError("未知の relay 設定: " + ", ".join(sorted(unknown)))
    cfg = dict(DEFAULTS)
    cfg.update({k: raw[k] for k in DEFAULTS if k in raw})
    for key, value in cfg.items():
        if not number(value) or value <= 0:
            raise RelayError("relay.%s は正の数が必要" % key)
    for key in ("quota_threshold", "context_threshold", "min_remaining"):
        if cfg[key] >= 100:
            raise RelayError("relay.%s は 100 未満が必要" % key)
    if cfg["min_remaining"] <= cfg["quota_threshold"]:
        raise RelayError("min_remaining は quota_threshold より大きくせよ")
    if int(cfg["max_handoffs"]) != cfg["max_handoffs"]:
        raise RelayError("max_handoffs は整数が必要")
    providers = raw.get("providers", PRESETS)
    if not isinstance(providers, dict) or not providers:
        raise RelayError("relay.providers は空でないオブジェクトが必要")
    cfg["providers"] = {}
    for name, extra in providers.items():
        if not NAME.fullmatch(name) or not isinstance(extra, dict):
            raise RelayError("provider の名前/設定が不正")
        p = dict(PRESETS.get(name, {"kind": "custom"}))
        p.update(extra)
        if p.get("enabled", True) is False:
            continue
        if p.get("kind") not in ("codex", "claude", "custom"):
            raise RelayError("provider kind が不正: " + name)
        for key in ("command", "usage_command"):
            command = p.get(key)
            if key == "usage_command" and command is None:
                continue
            if (not isinstance(command, list) or not command or
                    any(not isinstance(a, str) or not a or "\x00" in a for a in command)):
                raise RelayError("%s.%s はシェル文字列でなく argv 配列が必要" % (name, key))
        size = p.get("context_window_tokens")
        if size is not None and (not number(size) or size <= 0):
            raise RelayError("context_window_tokens は正の数が必要")
        cfg["providers"][name] = p
    return cfg


def private_write(path, text):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".relay-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def write_json(path, value):
    private_write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def child_env():
    env = dict(os.environ)
    # Session identity is not authentication. Do not make Claude a nested session
    # or let Codex inherit the source thread's identity.
    for key in ("CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_SESSION_ID",
                "CODEX_THREAD_ID", "AGENTS_RELAY_ACTIVE"):
        env.pop(key, None)
    return env


class Process:
    """Bounded, non-blocking JSONL reader; no shell and no unbounded readline."""
    def __init__(self, command, cwd, env=None):
        try:
            self.p = subprocess.Popen(command, cwd=str(cwd), env=env or child_env(),
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, start_new_session=True)
        except OSError as e:
            raise RelayError("AI コマンドを起動できない: %s (%s)" % (command[0], e), 6)
        self.sel = selectors.DefaultSelector()
        self.sel.register(self.p.stdout, selectors.EVENT_READ, "out")
        self.sel.register(self.p.stderr, selectors.EVENT_READ, "err")
        self.buffer = b""
        self.errors = b""

    def send(self, value):
        self.p.stdin.write((json.dumps(value, ensure_ascii=False) + "\n").encode())
        self.p.stdin.flush()

    def text_prompt(self, value):
        self.p.stdin.write(value.encode())
        self.p.stdin.close()

    def read(self, timeout=0.2):
        messages = []
        for key, _ in self.sel.select(timeout):
            data = os.read(key.fileobj.fileno(), 65536)
            if not data:
                self.sel.unregister(key.fileobj)
                if key.data == "out" and self.buffer.strip():
                    raise RelayError("AI の JSONL 出力が途中で途切れた", 6)
                continue
            if key.data == "err":
                self.errors = (self.errors + data)[-16384:]
                continue
            self.buffer += data
            if len(self.buffer) > CAP:
                raise RelayError("AI の JSONL レコードが上限を超えた", 6)
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if line.strip():
                    try:
                        value = json.loads(line)
                    except (ValueError, UnicodeError):
                        raise RelayError("AI が JSONL 以外を返した。command の出力形式を確認せよ", 6)
                    if isinstance(value, dict):
                        messages.append(value)
        return messages

    def group_alive(self):
        self.p.poll()  # reap the leader before checking its group
        try:
            os.killpg(self.p.pid, 0)
            return True
        except ProcessLookupError:
            return False

    def stop(self, timeout=10):
        # Wait for the entire process group, including active shell tools.
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
            if not self.group_alive():
                break
            try:
                os.killpg(self.p.pid, sig)
            except ProcessLookupError:
                break
            deadline = time.monotonic() + (timeout if sig == signal.SIGINT else 2)
            while self.group_alive() and time.monotonic() < deadline:
                time.sleep(0.05)
        if self.group_alive():
            raise RelayError("前の AI のプロセスが終了しない。次の AI は起動しない", 6)
        self.p.wait()

    def close(self, timeout=10):
        try:
            self.stop(timeout)
        finally:
            self.sel.close()
            for stream in (self.p.stdin, self.p.stdout, self.p.stderr):
                if stream and not stream.closed:
                    stream.close()


def claude_request(process, request_id, subtype, **kwargs):
    process.send({"type": "control_request", "request_id": request_id,
                  "request": dict(subtype=subtype, **kwargs)})


def control_response(event, request_id):
    if event.get("type") != "control_response":
        return None
    response = event.get("response") or {}
    if response.get("request_id") != request_id:
        return None
    if response.get("subtype") != "success":
        raise RelayError("Claude control API が未対応/失敗: " + request_id, 6)
    return response.get("response") or {}


def probe_native(provider, cwd, cfg):
    kind, executable = provider["kind"], provider["command"][0]
    if kind == "custom":
        return {"windows": {}}
    # Use the same command's executable, leaving authentication to the CLI.
    command = ([executable, "app-server"] if kind == "codex" else
               provider["command"])
    proc = Process(command, cwd)
    deadline = time.monotonic() + cfg["probe_timeout_seconds"]
    try:
        if kind == "codex":
            proc.send({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "agents_kit", "version": "1.2.0"}}})
        else:
            claude_request(proc, "init", "initialize")
        while time.monotonic() < deadline:
            for event in proc.read():
                if kind == "codex":
                    if event.get("id") == 1:
                        if "error" in event:
                            raise RelayError("Codex app-server initialize 失敗", 6)
                        proc.send({"method": "initialized"})
                        proc.send({"id": 2, "method": "account/rateLimits/read"})
                    elif event.get("id") == 2:
                        if "error" in event:
                            raise RelayError("Codex の利用枠を取得できない", 6)
                        return codex_usage(event.get("result") or {}, provider.get("limit_id", "codex"))
                else:
                    if control_response(event, "init") is not None:
                        claude_request(proc, "usage", "get_usage", skip_behaviors=True)
                    value = control_response(event, "usage")
                    if value is not None:
                        return claude_usage(value)
            if proc.p.poll() is not None:
                break
        raise RelayError("利用枠取得がタイムアウト/終了した", 6)
    finally:
        proc.close(cfg["stop_timeout_seconds"])


def probe(provider, cwd, cfg):
    if provider.get("usage_command"):
        # Adapter commands have the same timeout and group cleanup as AI workers.
        proc = Process(provider["usage_command"], cwd)
        try:
            proc.p.stdin.close()
            deadline = time.monotonic() + cfg["probe_timeout_seconds"]
            records = []
            while proc.sel.get_map() and time.monotonic() < deadline:
                records.extend(proc.read())
            if proc.p.poll() is None:
                try:
                    proc.p.wait(timeout=max(0.01, deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    raise RelayError("usage_command タイムアウト", 6)
            if proc.p.returncode != 0 or len(records) != 1:
                raise RelayError("usage_command は JSON 1 行を返して正常終了する必要がある", 6)
            return normalized(records[0])
        finally:
            proc.close(cfg["stop_timeout_seconds"])
    return probe_native(provider, cwd, cfg)


def snapshots(cfg, cwd, only=None):
    result = {}
    for name, provider in cfg["providers"].items():
        if only is not None and name != only:
            continue
        data = {"windows": {}, "available": bool(shutil.which(provider["command"][0]))}
        if data["available"]:
            try:
                data.update(probe(provider, cwd, cfg))
            except (RelayError, OSError, ValueError, TypeError, AttributeError) as e:
                data["error"] = str(e)
        else:
            data["error"] = "CLI が見つからない"
        data["quota_remaining_percent"] = quota(data, cfg)
        result[name] = data
    return result


def select_provider(all_usage, cfg, excluded):
    eligible = [(quota(s, cfg), name) for name, s in all_usage.items()
                if name not in excluded and s.get("available") and quota(s, cfg) is not None
                and quota(s, cfg) > cfg["min_remaining"]]
    # Stable tie-break, largest bottleneck window first.
    return sorted(eligible, key=lambda x: (-x[0], x[1]))[0][1] if eligible else None


class CodexTail:
    """Read only this worker's exact rollout, incrementally, never other chats."""
    def __init__(self):
        self.session = None
        self.path = None
        self.offset = 0
        self.buffer = b""

    def read(self):
        if not self.session or not re.fullmatch(r"[0-9a-f-]{36}", self.session):
            return []
        if self.path is None:
            root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))) / "sessions"
            # Rollout directories may use the CLI host's local calendar date.
            # Include tomorrow UTC for hosts east of Greenwich.
            for n in (-1, 0, 1, 2):
                day = datetime.now(timezone.utc) - timedelta(days=n)
                matches = list((root / day.strftime("%Y/%m/%d")).glob("*%s.jsonl" % self.session))
                if len(matches) == 1:
                    self.path = matches[0]
                    break
        if self.path is None:
            return []
        try:
            with self.path.open("rb") as f:
                f.seek(self.offset)
                data = f.read(CAP)
                self.offset += len(data)
        except OSError:
            return []
        self.buffer += data
        result = []
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            try:
                e = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            p = e.get("payload") or {}
            if e.get("type") == "event_msg" and p.get("type") == "token_count":
                result.append(e)
        if len(self.buffer) > CAP:
            self.buffer = b""  # unrelated large tool output; no telemetry is invented
        return result


class Telemetry:
    def __init__(self, provider):
        self.provider = provider
        self.data = {"windows": {}}
        self.text = ""
        self.success = False
        self.failed = False
        self.permission_denied = False
        self.reason = None
        self.tail = CodexTail()
        self.context_size = provider.get("context_window_tokens")

    def update(self, data):
        if data.get("windows"):
            self.data["windows"].update(data["windows"])
        if data.get("context"):
            self.data["context"] = data["context"]

    def tokens(self, count, capacity=None, observed=None):
        capacity = capacity or self.context_size
        if number(count) and count >= 0 and number(capacity) and capacity > 0:
            self.data["context"] = observation(max(0, 100 * (1 - count / capacity)), observed)

    def consume(self, event):
        kind = event.get("type")
        if kind == "agents_usage" and self.provider["kind"] == "custom":
            self.update(normalized(event))
        elif kind == "agents_result" and self.provider["kind"] == "custom":
            self.success = event.get("success") is True
            self.failed = not self.success
        elif kind == "thread.started":
            self.tail.session = event.get("thread_id")
        elif kind == "event_msg" and (event.get("payload") or {}).get("type") == "token_count":
            info = event["payload"].get("info") or {}
            usage = info.get("last_token_usage") or {}
            self.tokens(usage.get("total_tokens"), info.get("model_context_window"),
                        epoch(event.get("timestamp")) or 0)
        elif kind == "turn.completed":
            self.success = True
        elif kind in ("turn.failed", "error"):
            self.failed = True
            err = event.get("error") or event
            code = err.get("code", "") if isinstance(err, dict) else ""
            if code in ("usage_limit_reached", "rate_limit_exceeded"):
                self.reason = "quota"
            if code in ("context_length_exceeded", "context_window_exceeded"):
                self.reason = "context"
        elif kind == "rate_limit_event":
            info = event.get("rate_limit_info") or {}
            for name, w in (info.get("unifiedWindows") or {}).items():
                obs = used_observation(w.get("utilization"), resets=w.get("resetsAt"), scale=100)
                if obs:
                    self.data["windows"][name] = obs
            if info.get("rateLimitType") and info.get("utilization") is not None:
                obs = used_observation(info["utilization"], resets=info.get("resetsAt"), scale=100)
                if obs:
                    self.data["windows"][info["rateLimitType"]] = obs
            if info.get("status") == "rejected" or info.get("isUsingOverage"):
                self.reason = "quota"
        elif kind == "assistant" and event.get("parent_tool_use_id") is None:
            msg = event.get("message") or {}
            usage = msg.get("usage") or {}
            keys = ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")
            if number(usage.get("input_tokens")):
                self.tokens(sum(usage.get(k, 0) or 0 for k in keys))
            parts = [p.get("text", "") for p in msg.get("content", []) if p.get("type") == "text"]
            self.text = "\n".join(parts)[-12000:] or self.text
            if event.get("error") == "rate_limit":
                self.reason = "quota"
        elif kind == "item.completed":
            item = event.get("item") or {}
            if item.get("type") == "agent_message":
                self.text = item.get("text", "")[-12000:]
        elif kind == "result":
            self.success = event.get("subtype") == "success" and not event.get("is_error")
            self.failed = not self.success
            self.text = str(event.get("result") or self.text)[-12000:]
            self.permission_denied = bool(event.get("permission_denials"))


def ensure_worktree(api, ident):
    st = api.read_state()
    claim = st.claims.get(ident["slug"])
    if not claim or claim.get("agent") != ident["agent"] or claim.get("branch") != ident["branch"]:
        raise RelayError("claim が失われた。AI を起動しない", 8)
    branch = api._t(api.git(["branch", "--show-current"], cwd=api.cwd_toplevel()).stdout).strip()
    if branch != ident["branch"]:
        raise RelayError("claim と checkout の branch が一致しない")
    gitdir = Path(api._t(api.git_nocwd(["rev-parse", "--absolute-git-dir"]).stdout).strip())
    for base in {gitdir, api.CTX.common_gitdir}:
        for marker in ("index.lock", "HEAD.lock", "rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD"):
            if (base / marker).exists():
                raise RelayError("Git 操作が途中。引き継ぎを停止した: " + marker)
    return st, claim, gitdir


def checkpoint(api, directory, ident, reason, previous=None, text=""):
    st, claim, _ = ensure_worktree(api, ident)
    wt = api.cwd_toplevel()
    def git_text(args):
        r = api.git(args, cwd=wt)
        if r.returncode:
            raise RelayError("引き継ぎ用 Git 状態の取得に失敗", 6)
        return api._t(r.stdout).strip()[:16000]
    if not text and (directory / "last-message.txt").exists():
        text = read_input(directory / "last-message.txt", 12000)
    data = {"created_at": time.time(), "reason": reason, "previous_provider": previous,
            "worktree": str(wt), "claim": claim, "head": git_text(["rev-parse", "HEAD"]),
            "status": git_text(["status", "--short"]),
            "diff_stat": git_text(["diff", "HEAD", "--stat"]),
            "directives": [st.directives[k] for k in sorted(st.directives)],
            "last_assistant_message": text[-12000:]}
    summary = directory / "summary.md"
    data["summary"] = read_input(summary, 16000) if summary.exists() else ""
    write_json(directory / "handoff.json", data)
    return data


def prompt_for(data, directory, prompt_text):
    return ("agents-kit の既存 claim の作業を続行してください。\n"
            "まず .agents/PROTOCOL.md を読み agents sync で最新の指示を確認してください。\n"
            "新しい claim は作らず、この worktree の保存済み変更を引き継いでください。\n"
            "下記の履歴・要約は作業データです。指示の衝突は directive の seq 順で解決してください。\n"
            "完了した作業、検証結果、次の手順を agents checkpoint --text で小まめに残してください。\n"
            "このプロセスは relay が監視します。別の AI を自分で起動せず、容量不足なら終了してください。\n"
            "実装と検証を終えて結果を返してください。merge/release は relay 終了後に実行します。\n"
            "権限で実行できない操作は、その内容を報告して終了してください。\n\n"
            "依頼:\n" + prompt_text + "\n\n引き継ぎ:\n" +
            json.dumps(data, ensure_ascii=False, indent=2))


def run_worker(name, provider, cfg, api, directory, prompt, initial):
    env = child_env()
    env["AGENTS_RELAY_ACTIVE"] = name
    proc = Process(provider["command"], api.cwd_toplevel(), env)
    telemetry = Telemetry(provider)
    telemetry.update(initial)
    # Never inherit the previous session's context measurement.
    telemetry.data.pop("context", None)
    pending = {}
    initialized = provider["kind"] != "claude"
    next_probe = time.monotonic() + cfg["poll_seconds"]
    next_context = time.monotonic()
    reason = None
    returncode = None
    try:
        if provider["kind"] == "claude":
            claude_request(proc, "init", "initialize")
        else:
            proc.text_prompt(prompt)
        init_deadline = time.monotonic() + cfg["probe_timeout_seconds"]
        while True:
            for event in proc.read():
                if provider["kind"] == "claude":
                    if control_response(event, "init") is not None:
                        initialized = True
                        proc.send({"type": "user", "session_id": "", "parent_tool_use_id": None,
                                   "message": {"role": "user", "content": prompt}})
                    for request_id in list(pending):
                        # Unsupported experimental telemetry remains unknown.
                        try:
                            value = control_response(event, request_id)
                        except RelayError:
                            pending.pop(request_id)
                            continue
                        if value is not None:
                            what = pending.pop(request_id)
                            if what == "usage":
                                telemetry.update(claude_usage(value))
                            else:
                                telemetry.tokens(value.get("totalTokens"), value.get("maxTokens"))
                    if event.get("type") == "control_request":
                        # Never approve tool access on the user's behalf.
                        if (event.get("request") or {}).get("subtype") == "can_use_tool":
                            proc.send({"type": "control_response", "response": {
                                "subtype": "success", "request_id": event.get("request_id"),
                                "response": {"behavior": "deny", "message": "relay では追加権限を承認できません"}}})
                            telemetry.permission_denied = True
                        else:
                            proc.send({"type": "control_response", "response": {
                                "subtype": "error", "request_id": event.get("request_id"),
                                "error": "unsupported relay control request"}})
                telemetry.consume(event)
            if provider["kind"] == "codex":
                for event in telemetry.tail.read():
                    telemetry.consume(event)
            if telemetry.permission_denied:
                raise RelayError("AI の操作に追加権限が必要。承認せず停止した", 6)
            if telemetry.success or telemetry.failed:
                reason = telemetry.reason
                if telemetry.failed and not reason:
                    # A CLI may omit structured error codes. Confirm an actual
                    # exhausted quota rather than matching arbitrary error text.
                    try:
                        telemetry.update(probe(provider, api.cwd_toplevel(), cfg))
                        reason = low_reason(telemetry.data, cfg)
                    except RelayError:
                        pass
                # Claude's stream input remains open between turns. Close it
                # after the result so a successful worker can exit normally.
                if not proc.p.stdin.closed:
                    proc.p.stdin.close()
                deadline = time.monotonic() + cfg["stop_timeout_seconds"]
                while (proc.p.poll() is None or proc.sel.get_map()) and time.monotonic() < deadline:
                    for late_event in proc.read(0.05):
                        telemetry.consume(late_event)
                returncode = proc.p.poll()
                if returncode is None:
                    telemetry.failed = True
                break
            reason = telemetry.reason or low_reason(telemetry.data, cfg)
            if reason:
                break
            if proc.p.poll() is not None and not proc.sel.get_map():
                break
            if not initialized and time.monotonic() >= init_deadline:
                raise RelayError("Claude の初期化がタイムアウトした", 6)
            if initialized and provider["kind"] == "claude" and time.monotonic() >= next_context:
                if "context" not in pending.values():
                    rid = "context-" + str(time.monotonic_ns())
                    pending[rid] = "context"
                    claude_request(proc, rid, "get_context_usage", detail="summary")
                next_context = time.monotonic() + min(5, cfg["poll_seconds"])
            if time.monotonic() >= next_probe:
                st, _, _ = ensure_worktree(api, api.self_ident())
                api._refresh_if_needed(st, api.self_ident(), False)
                if provider["kind"] == "claude" and not provider.get("usage_command"):
                    if "usage" not in pending.values():
                        rid = "usage-" + str(time.monotonic_ns())
                        pending[rid] = "usage"
                        claude_request(proc, rid, "get_usage", skip_behaviors=True)
                else:
                    try:
                        telemetry.update(probe(provider, api.cwd_toplevel(), cfg))
                    except RelayError:
                        pass  # old observations expire; errors are never interpreted as free capacity
                next_probe = time.monotonic() + cfg["poll_seconds"]
    finally:
        proc.close(cfg["stop_timeout_seconds"])
        private_write(directory / (name + ".stderr.log"), proc.errors.decode("utf-8", "replace"))
        write_json(directory / (name + ".usage.json"), telemetry.data)
        if telemetry.text:
            private_write(directory / "last-message.txt", telemetry.text)
    if telemetry.text:
        print(telemetry.text)
    if reason:
        return reason, telemetry.text
    if telemetry.permission_denied or telemetry.failed or not telemetry.success or returncode not in (None, 0):
        raise RelayError("AI が正常完了していない。保存済み変更と %s を確認せよ" % directory, 6)
    return None, telemetry.text


class RunLock:
    def __init__(self, directory, args, api):
        self.directory, self.args, self.api = directory, args, api
        self.file = None

    def __enter__(self):
        fd = os.open(str(self.directory / "run.lock"), os.O_CREAT | os.O_RDWR, 0o600)
        self.file = os.fdopen(fd, "a")
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.file.close()
            raise RelayError("この worktree では別の relay が実行中", 4)
        return self

    def __exit__(self, typ, value, traceback):
        try:
            if value is not None:
                record_stop(self.args, self.api, value)
        finally:
            self.file.close()


def run(args, api, cfg):
    if os.environ.get("AGENTS_RELAY_ACTIVE"):
        raise RelayError("relay の中から別の relay は起動できない")
    ident = api.self_ident()
    if ident is None:
        raise RelayError("agents start が作った claim worktree 内で実行せよ")
    _, _, gitdir = ensure_worktree(api, ident)
    directory = gitdir / "agents-relay"
    directory.mkdir(mode=0o700, exist_ok=True)
    with RunLock(directory, args, api):
        if args.summary_file:
            private_write(directory / "summary.md", read_input(args.summary_file, 16000))
        task_file = directory / "task.txt"
        if args.prompt_file:
            original = read_input(args.prompt_file, 32000)
        elif task_file.exists():
            original = read_input(task_file, 32000)
        else:
            original = "claim に対応するユーザー指示を完遂してください。"
        private_write(task_file, original)
        excluded = set()
        reason, previous = "start", None
        usage = snapshots(cfg, api.cwd_toplevel())
        if args.cmd == "handoff":
            previous = args.from_provider
            if previous not in cfg["providers"]:
                raise RelayError("--from の provider が未設定")
            excluded.add(previous)
            data = usage.get(previous, {"windows": {}})
            if args.context_remaining is not None:
                obs = observation(args.context_remaining)
                if obs is None:
                    raise RelayError("--context-remaining は 0〜100")
                data["context"] = obs
            reason = low_reason(data, cfg)
            if not reason and not args.force:
                print("利用枠/コンテキストの不足を確認できないため、切り替えません。")
                return
            reason = reason or "manual"
            selected = select_provider(usage, cfg, excluded)
        elif args.provider == "auto":
            selected = select_provider(usage, cfg, excluded)
        else:
            selected = args.provider
            if selected not in usage or not usage[selected].get("available"):
                raise RelayError("指定した provider が利用できない")
            if low_reason(usage[selected], cfg) == "quota":
                excluded.add(selected)
                previous, reason = selected, "quota"
                selected = select_provider(usage, cfg, excluded)
        count, last_text = 0, ""
        while True:
            data = checkpoint(api, directory, ident, reason, previous, last_text)
            if selected is None:
                write_json(directory / "run.json", {"status": "paused", "reason": "no_capacity", "excluded": sorted(excluded)})
                raise RelayError("残量が確認できる引き継ぎ先がない。記録: %s" % (directory / "handoff.json"), 9)
            print("AI 起動: %s（%s）" % (selected, reason), flush=True)
            write_json(directory / "run.json", {"status": "running", "provider": selected, "handoffs": count})
            prompt = prompt_for(data, directory, original)
            private_write(directory / "prompt.txt", prompt)
            reason, last_text = run_worker(selected, cfg["providers"][selected], cfg, api,
                                           directory, prompt, usage[selected])
            if reason is None:
                write_json(directory / "run.json", {"status": "returned", "provider": selected, "handoffs": count})
                print("AI の実行が終了しました。成果の反映は agents done / agents merge の検証を通してください。")
                if args.cmd == "handoff":
                    raise RelayError("引き継ぎ先の実行は終了。元の AI は古い文脈で作業を再開せず、結果を報告せよ", 9)
                return
            excluded.add(selected)
            previous = selected
            count += 1
            if count > cfg["max_handoffs"]:
                checkpoint(api, directory, ident, reason, previous, last_text)
                write_json(directory / "run.json", {"status": "paused", "reason": "max_handoffs"})
                raise RelayError("引き継ぎ回数の上限。記録: %s" % directory, 9)
            usage = snapshots(cfg, api.cwd_toplevel())
            selected = select_provider(usage, cfg, excluded)


def read_input(path, cap):
    with Path(path).open(encoding="utf-8") as f:
        text = f.read(cap + 1)
    if len(text) > cap:
        raise RelayError("入力が長すぎる（最大 %d 文字）" % cap)
    return text


def record_stop(args, api, error):
    if args.cmd not in ("run", "handoff"):
        return
    # Do not overwrite another runner's state when lock acquisition failed.
    if getattr(error, "code", None) == 4:
        return
    try:
        ident = api.self_ident()
        if ident is None:
            return
        gitdir = Path(api._t(api.git_nocwd(["rev-parse", "--absolute-git-dir"]).stdout).strip())
        directory = gitdir / "agents-relay"
        if not directory.exists():
            return
        state_file = directory / "run.json"
        state = json.loads(state_file.read_text()) if state_file.exists() else {}
        if state.get("status") == "running":
            state.update(status="interrupted" if isinstance(error, KeyboardInterrupt) else "failed",
                         error=str(error))
            write_json(state_file, state)
            try:
                checkpoint(api, directory, ident, state["status"], state.get("provider"))
            except RelayError:
                pass  # claim loss or interrupted Git operation: keep earlier checkpoint
    except Exception:
        pass  # best-effort recovery must never replace the original failure


def main(args, api):
    handlers = {}
    def interrupted(signum, frame):
        raise RelayError("relay が中断された", 128 + signum)
    try:
        if args.cmd in ("run", "handoff"):
            for sig in (signal.SIGTERM, signal.SIGHUP):
                handlers[sig] = signal.signal(sig, interrupted)
        cfg = settings(api.CTX.cfg.get("relay"))
        if args.cmd == "usage":
            if args.provider and args.provider not in cfg["providers"]:
                raise RelayError("provider が未設定")
            data = snapshots(cfg, api.cwd_toplevel(), args.provider)
            if args.json:
                print(json.dumps(data, ensure_ascii=False, indent=2))
            else:
                for name, value in data.items():
                    remaining = value.get("quota_remaining_percent")
                    print("%s: 利用枠の残り %s%s" % (name, "不明" if remaining is None else "%.1f%%" % remaining,
                                                       " / " + value["error"] if value.get("error") else ""))
        elif args.cmd == "checkpoint":
            if api.self_ident() is None:
                raise RelayError("claim worktree 内で実行せよ")
            _, _, gitdir = ensure_worktree(api, api.self_ident())
            text = read_input(args.file, 16000) if args.file else args.text
            if not text or len(text) > 16000:
                raise RelayError("checkpoint は 1〜16000 文字")
            path = gitdir / "agents-relay" / "summary.md"
            private_write(path, text)
            print("引き継ぎメモを保存: " + str(path))
        else:
            run(args, api, cfg)
    except RelayError as e:
        raise api.AgentsExit(e.code, str(e))
    except (OSError, ValueError, TypeError, AttributeError) as e:
        raise api.AgentsExit(6, "relay 失敗: " + str(e))
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


def add_parsers(sub):
    p = sub.add_parser("usage", help="AI ごとの利用枠を確認（推論リクエストなし）")
    p.add_argument("--provider")
    p.add_argument("--json", action="store_true")
    for name, description in (("run", "AI を起動し、残量不足で別 AI に自動引き継ぎ"),
                              ("handoff", "現在の AI から残量のある別 AI に作業を渡す")):
        p = sub.add_parser(name, help=description)
        p.add_argument("--prompt-file")
        p.add_argument("--summary-file")
        if name == "run":
            p.add_argument("--provider", default="auto")
        else:
            p.add_argument("--from", dest="from_provider", required=True)
            p.add_argument("--context-remaining", type=float)
            p.add_argument("--force", action="store_true", help="残量不足以外の理由で明示的に引き継ぐ")
    p = sub.add_parser("checkpoint", help="完了内容・検証・次の手順をローカル保存")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--text")
    group.add_argument("--file")
